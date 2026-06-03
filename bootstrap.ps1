#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Triage', 'Repair', 'W11Readiness', 'MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'ExportBundle')]
    [string]$Mode = 'Triage',

    [string[]]$BackupUsers = @(),
    [string[]]$BackupFolders = @(),
    [string[]]$BackupApps = @(),
    [string]$BackupDestination = $null,
    [switch]$BackupExecute,
    [switch]$BackupIncludePrivateKeys,
    [switch]$BackupIncludeAppData,
    [switch]$BackupHashSample,
    [switch]$SkipBackupAppList,
    [string]$BackupProfilesRoot = $null,

    [string]$RestoreBackupPath = $null,
    [string]$RestoreRoot = $null,
    [string[]]$RestoreFolders = @(),
    [switch]$RestoreExecute,
    [switch]$RestoreHashSample,
    [string]$RestoreAsUser = $null,

    [string]$VerifyBackupPath = $null,

    [string]$AppsBackupPath = $null,
    [switch]$AppsExecute,
    [string[]]$AppsSelect = @()
)

$validWinPulseModes = @('Triage', 'Repair', 'W11Readiness', 'MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'ExportBundle')
$modeOverride = $null
$globalMode = Get-Variable -Name WinPulseMode -Scope Global -ErrorAction SilentlyContinue
if ($globalMode -and -not [string]::IsNullOrWhiteSpace([string]$globalMode.Value)) {
    $modeOverride = [string]$globalMode.Value
}
elseif (-not [string]::IsNullOrWhiteSpace($env:WINPULSE_MODE)) {
    $modeOverride = [string]$env:WINPULSE_MODE
}

if ($modeOverride) {
    if ($modeOverride -notin $validWinPulseModes) {
        throw ('Invalid WinPulse mode override "{0}". Valid modes: {1}' -f $modeOverride, ($validWinPulseModes -join ', '))
    }
    $Mode = $modeOverride
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WinPulse UI is English. Render numbers culture-invariant (dot decimal) so the
# dashboard and reports are consistent regardless of the machine locale.
try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture } catch { }

$script:WinPulseVersion = '0.13.0-20260603'

function Test-WinPulseIsAdmin {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-WinPulseElevation {
    [CmdletBinding()]
    param(
        [string]$bootstrappath,
        [string]$bootstrapdefinition,
        [string]$bootstrapurl,
        [string]$mode,
        [string[]]$passthrougharguments = @(),
        [switch]$skipElevation
    )

    if ($skipElevation) {
        return
    }

    if (Test-WinPulseIsAdmin) {
        return
    }

    $shellPath = (Get-Command -Name powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $shellPath) {
        $shellPath = (Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue).Source
    }

    if (-not $shellPath) {
        throw 'Unable to find PowerShell executable for elevation.'
    }

    $sourcePath = $bootstrappath
    if ($sourcePath -and (Test-Path -Path $sourcePath)) {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $sourcePath))
    }
    elseif ($bootstrapurl) {
        $tempScript = Join-Path -Path $env:TEMP -ChildPath ('WinPulse-Bootstrap-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
        Invoke-WebRequest -Uri $bootstrapurl -OutFile $tempScript -UseBasicParsing
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $tempScript))
    }
    else {
        if (-not $bootstrapdefinition) {
            throw 'Cannot self-elevate from in-memory invocation: no script body found.'
        }

        $tempScript = Join-Path -Path $env:TEMP -ChildPath ('WinPulse-Bootstrap-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
        [IO.File]::WriteAllText($tempScript, $bootstrapdefinition, [Text.UTF8Encoding]::new($false))
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $tempScript))
    }

    if ($mode -in @('W11Readiness', 'MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'ExportBundle')) {
        $args = @('-NoExit') + $args
    }

    if ($mode) {
        $args += @('-Mode', ('"{0}"' -f $mode))
    }

    foreach ($argument in @($passthrougharguments)) {
        $args += $argument
    }

    Start-Process -FilePath $shellPath -Verb RunAs -ArgumentList ($args -join ' ')
    exit
}

$script:WinPulsePaths = [ordered]@{
    Root    = 'C:\ProgramData\WinPulse'
    Bin     = 'C:\ProgramData\WinPulse\bin'
    Logs    = 'C:\ProgramData\WinPulse\logs'
    Exports = 'C:\ProgramData\WinPulse\exports'
    Backups = 'C:\ProgramData\WinPulse\backups'
    Modules = 'C:\ProgramData\WinPulse\modules'
    Config  = $null
}

function ConvertTo-ReadableSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [double]$bytes
    )

    if ($bytes -lt 1KB) { return ('{0:N0} B' -f $bytes) }
    if ($bytes -lt 1MB) { return ('{0:N2} KB' -f ($bytes / 1KB)) }
    if ($bytes -lt 1GB) { return ('{0:N2} MB' -f ($bytes / 1MB)) }
    if ($bytes -lt 1TB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    return ('{0:N2} TB' -f ($bytes / 1TB))
}

function Get-WinPulseTimestamp {
    [CmdletBinding()]
    param()

    return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

function Resolve-WinPulsePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$childpath
    )

    return (Join-Path -Path $script:WinPulsePaths.Root -ChildPath $childpath)
}

function Get-WinPulseDiskBar {
    param([double]$Percent, [int]$Width = 10)
    $filled = [math]::Min($Width, [math]::Floor($Width * $Percent / 100))
    $empty  = $Width - $filled
    return '[{0}{1}]' -f ('#' * $filled), ('.' * $empty)
}

function Get-WinPulseStateFromPercent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [double]$percent,

        [double]$warning = 70,
        [double]$critical = 90,

        [switch]$inverse
    )

    if ($inverse) {
        if ($percent -le $critical) { return 'Critical' }
        if ($percent -le $warning) { return 'Warning' }
        return 'OK'
    }

    if ($percent -ge $critical) { return 'Critical' }
    if ($percent -ge $warning) { return 'Warning' }
    return 'OK'
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$level,

        [Parameter(Mandatory = $true)]
        [string]$message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $level, $message

    try {
        if (-not $script:WinPulsePaths -or -not $script:WinPulsePaths.Logs) {
            Write-Host $line
            return
        }

        $logFile = Join-Path $script:WinPulsePaths.Logs ('WinPulse-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    }
    catch {
        Write-Host $line
        Write-Host ('[LOGGER] Failed to write log file: {0}' -f $_.Exception.Message)
    }
}

function Initialize-WinPulse {
    [CmdletBinding()]
    param()

    foreach ($path in @(
        $script:WinPulsePaths.Root,
        $script:WinPulsePaths.Bin,
        $script:WinPulsePaths.Logs,
        $script:WinPulsePaths.Exports,
        $script:WinPulsePaths.Backups,
        $script:WinPulsePaths.Modules
    )) {
        if (-not (Test-Path -Path $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    $configPath = Join-Path $script:WinPulsePaths.Root 'config.json'
    if (-not (Test-Path -Path $configPath)) {
        $defaultConfig = [ordered]@{
            version = '1.0.0'
            created = (Get-Date).ToString('o')
            telemetry = $false
        }
        $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content -Path $configPath -Encoding UTF8
    }

    $script:WinPulsePaths.Config = $configPath
    Write-Log -level 'INFO' -message ("WinPulse initialized at {0}" -f $script:WinPulsePaths.Root)
}

function Test-WinPulsePendingReboot {
    [CmdletBinding()]
    param()

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    if (Test-Path -Path $paths[0]) { return $true }
    if (Test-Path -Path $paths[1]) { return $true }

    try {
        $sessionMgr = Get-ItemProperty -Path $paths[2] -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($sessionMgr.PendingFileRenameOperations) {
            return $true
        }
    }
    catch {
    }

    return $false
}

function Get-WinPulseFirmwareMode {
    [CmdletBinding()]
    param()

    try {
        $fw = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop
        switch ([int]$fw.PEFirmwareType) {
            1 { return 'BIOS' }
            2 { return 'UEFI' }
            default { return 'Unknown' }
        }
    }
    catch {
        if (Test-Path -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') {
            return 'UEFI'
        }
        return 'Unknown'
    }
}

function Get-WinPulseSecureBootState {
    [CmdletBinding()]
    param(
        [string]$firmwaremode
    )

    if ($firmwaremode -eq 'BIOS') {
        return 'N/A (BIOS)'
    }

    try {
        $state = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($state) {
            return 'On'
        }
        return 'Off'
    }
    catch {
        return 'Unknown'
    }
}

function Get-WinPulseAntivirusProducts {
    [CmdletBinding()]
    param()

    $products = @()
    try {
        $rows = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop
        foreach ($row in $rows) {
            $name = ''
            if ($row.PSObject.Properties['displayName']) {
                $name = [string]$row.displayName
            }

            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $stateRaw = 0
            if ($row.PSObject.Properties['productState']) {
                $stateRaw = [int]$row.productState
            }

            $products += [pscustomobject]@{
                Name = $name
                ProductState = ('0x{0:X6}' -f $stateRaw)
                IsMicrosoft = ($name -match 'Windows Defender|Microsoft Defender')
            }
        }
    }
    catch {
    }

    return $products
}

function Get-WinPulseWuErrorCategory {
    [CmdletBinding()]
    param(
        [string]$code,
        [string]$message
    )

    $normalizedCode = ''
    if ($code) {
        $normalizedCode = $code.ToUpperInvariant()
    }

    if ($normalizedCode -in @('0X80073D02', '0X80073CF9', '0X80073D0A') -or $message -match 'Microsoft\.[A-Za-z0-9\.]+') {
        return 'StoreApps'
    }
    if ($normalizedCode -like '0X8024*') {
        return 'UpdateService'
    }
    if ($normalizedCode -like '0X80072*') {
        return 'Network'
    }
    if ($normalizedCode -like '0X800F*') {
        return 'Servicing'
    }
    if ($normalizedCode -eq '0X80070005') {
        return 'AccessDenied'
    }
    if ($normalizedCode -eq 'N/A' -and $message -match 'internet|network|dns|proxy|server') {
        return 'Network'
    }

    return 'General'
}

function Get-WinPulseRepairPlans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    $plans = @()

    if ($scan.Health.PendingReboot) {
        $plans += [pscustomobject]@{
            Id = 'pending_reboot'
            Label = 'Reboot Device'
            Reason = 'Pending reboot detected.'
            Steps = @(
                'Save open work and reboot the workstation.',
                'Run WinPulse again after reboot and compare HEALTH section.'
            )
        }
    }

    if ($scan.Health.WindowsUpdateErrorCount24Hours -gt 0) {
        $plans += [pscustomobject]@{
            Id = 'wu_services'
            Label = 'Restart Windows Update Services'
            Reason = 'Basic first-step for transient Windows Update failures.'
            Steps = @(
                'Restart services: wuauserv, bits, cryptsvc, msiserver.',
                'Re-scan system state after service restart.'
            )
        }

        if ($scan.Health.WindowsUpdateCategoryCounts.StoreApps -gt 0) {
            $plans += [pscustomobject]@{
                Id = 'store_apps'
                Label = 'Repair Store/AppX Update Flow'
                Reason = ('Store/AppX related errors: {0}' -f $scan.Health.WindowsUpdateCategoryCounts.StoreApps)
                Steps = @(
                    'Stop common Store/AppX host processes (where possible).',
                    'Reset Store cache using wsreset.exe.',
                    'Restart update-related services (InstallService, ClipSVC, wuauserv, bits).'
                )
            }
        }
        if ($scan.Health.WindowsUpdateCategoryCounts.Network -gt 0 -or -not $scan.Network.Internet) {
            $plans += [pscustomobject]@{
                Id = 'network_stack'
                Label = 'Repair Network Stack'
                Reason = 'Network-related update failures detected.'
                Steps = @(
                    'Flush DNS cache.',
                    'Reset TCP/IP and Winsock.',
                    'Restart active network adapters.'
                )
            }
        }
        if ($scan.Health.WindowsUpdateCategoryCounts.UpdateService -gt 0 -or
            $scan.Health.WindowsUpdateCategoryCounts.Servicing -gt 0 -or
            $scan.Health.WindowsUpdateCategoryCounts.General -gt 0) {
            $plans += [pscustomobject]@{
                Id = 'wu_components'
                Label = 'Reset Windows Update Components'
                Reason = 'Windows Update service/servicing errors detected.'
                Steps = @(
                    'Stop wuauserv, bits, cryptsvc, msiserver.',
                    'Rename SoftwareDistribution and catroot2 as backups.',
                    'Start all stopped services again.'
                )
            }
        }
    }

    $diskC = $scan.Hardware.Disks | Where-Object { $_.Drive -eq 'C:' } | Select-Object -First 1
    if ($diskC -and [double]$diskC.UsedPercent -ge 85) {
        $plans += [pscustomobject]@{
            Id = 'temp_cleanup'
            Label = 'Clean Temporary Files'
            Reason = ('System drive usage is high ({0}%).' -f $diskC.UsedPercent)
            Steps = @(
                'Clear WinPulse temporary artifacts only (safe scope).',
                'Re-scan disk usage and retry failed operations.'
            )
        }
    }

    if (-not $scan.Network.Internet -and -not ($plans | Where-Object { $_.Id -eq 'network_stack' })) {
        $plans += [pscustomobject]@{
            Id = 'network_stack'
            Label = 'Repair Network Stack'
            Reason = 'No internet connectivity detected.'
            Steps = @(
                'Flush DNS cache.',
                'Reset TCP/IP and Winsock.',
                'Restart active network adapters.'
            )
        }
    }

    if ($scan.Health.CriticalLast24Hours -gt 0 -or $scan.Health.WindowsUpdateCategoryCounts.Servicing -gt 0) {
        $plans += [pscustomobject]@{
            Id = 'system_files'
            Label = 'Repair System Files (DISM + SFC)'
            Reason = 'Critical/servicing signals suggest system file integrity check.'
            Steps = @(
                'Run DISM /Online /Cleanup-Image /RestoreHealth.',
                'Run SFC /scannow.'
            )
        }
    }

    return $plans
}

# -- Extended Diagnostic Helpers ----------------------------------------------

function Get-WinPulseHardwareDetail {
    [CmdletBinding()]
    param()

    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $archMap = @{ 0 = 'x86'; 5 = 'ARM'; 6 = 'IA64'; 9 = 'x64'; 12 = 'ARM64' }
    $cpuInfo = [ordered]@{
        Model       = if ($cpu) { $cpu.Name.Trim() } else { 'N/A' }
        Cores       = if ($cpu) { [int]$cpu.NumberOfCores } else { 0 }
        Threads     = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { 0 }
        BaseFreqMHz = if ($cpu) { [int]$cpu.MaxClockSpeed } else { 0 }
        Architecture = if ($cpu -and $archMap.ContainsKey([int]$cpu.Architecture)) { $archMap[[int]$cpu.Architecture] } else { 'Unknown' }
    }

    $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    $gpuList = @()
    foreach ($gpu in $gpus) {
        $vram = if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) { ConvertTo-ReadableSize -bytes ([double]$gpu.AdapterRAM) } else { 'N/A' }
        $res = if ($gpu.CurrentHorizontalResolution -and $gpu.CurrentVerticalResolution) { '{0}x{1}' -f $gpu.CurrentHorizontalResolution, $gpu.CurrentVerticalResolution } else { 'N/A' }
        $gpuList += [ordered]@{
            Name          = if ($gpu.Name) { $gpu.Name.Trim() } else { 'N/A' }
            DriverVersion = if ($gpu.DriverVersion) { $gpu.DriverVersion } else { 'N/A' }
            VRAM          = $vram
            Resolution    = $res
        }
    }

    $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $typeMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 22 = 'DDR2 FB-DIMM'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }
    $dimmList = @()
    foreach ($dimm in $dimms) {
        $slot = if ($dimm.DeviceLocator) { $dimm.DeviceLocator } elseif ($dimm.BankLabel) { $dimm.BankLabel } else { 'N/A' }
        $memType = if ($dimm.SMBIOSMemoryType -and $typeMap.ContainsKey([int]$dimm.SMBIOSMemoryType)) { $typeMap[[int]$dimm.SMBIOSMemoryType] } else { 'Unknown' }
        $dimmList += [ordered]@{
            Slot         = $slot
            Capacity     = if ($dimm.Capacity) { ConvertTo-ReadableSize -bytes ([double]$dimm.Capacity) } else { 'N/A' }
            SpeedMHz     = if ($dimm.Speed) { [int]$dimm.Speed } else { 0 }
            Type         = $memType
            Manufacturer = if ($dimm.Manufacturer -and $dimm.Manufacturer.Trim()) { $dimm.Manufacturer.Trim() } else { 'Unknown' }
        }
    }

    $batteryInfo = [ordered]@{ Present = $false; HealthPercent = $null; CycleCount = $null; DesignCapacityWh = $null; FullChargeCapacityWh = $null }
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        $batteryInfo.Present = $true
        try {
            $bStatic = Get-CimInstance -Namespace root\WMI -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
            $bFull = Get-CimInstance -Namespace root\WMI -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($bStatic -and $bStatic.DesignedCapacity -and $bFull -and $bFull.FullChargedCapacity) {
                $batteryInfo.DesignCapacityWh = [math]::Round($bStatic.DesignedCapacity / 1000, 1)
                $batteryInfo.FullChargeCapacityWh = [math]::Round($bFull.FullChargedCapacity / 1000, 1)
                if ($bStatic.DesignedCapacity -gt 0) {
                    $batteryInfo.HealthPercent = [math]::Round(($bFull.FullChargedCapacity / $bStatic.DesignedCapacity) * 100, 1)
                }
            }
            if ($bStatic -and $bStatic.PSObject.Properties['CycleCount']) {
                $batteryInfo.CycleCount = [int]$bStatic.CycleCount
            }
        }
        catch { }
        # Fallback 1: Win32_Battery.DesignCapacity / FullChargeCapacity
        if (-not $batteryInfo.HealthPercent) {
            try {
                $dc = [int]($battery | Select-Object -ExpandProperty DesignCapacity -ErrorAction SilentlyContinue)
                $fc = [int]($battery | Select-Object -ExpandProperty FullChargeCapacity -ErrorAction SilentlyContinue)
                if ($dc -gt 0 -and $fc -gt 0) {
                    $batteryInfo.DesignCapacityWh    = [math]::Round($dc / 1000, 1)
                    $batteryInfo.FullChargeCapacityWh = [math]::Round($fc / 1000, 1)
                    $batteryInfo.HealthPercent        = [math]::Round(($fc / $dc) * 100, 1)
                }
            }
            catch { }
        }
        # Fallback 2: powercfg /batteryreport - reliable on all Windows laptops
        if (-not $batteryInfo.HealthPercent) {
            try {
                $tmpHtml = Join-Path $env:TEMP 'winpulse-batt.html'
                $pcfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
                if (-not (Test-Path -LiteralPath $pcfg)) { $pcfg = 'powercfg' }
                $null = & $pcfg /batteryreport /output $tmpHtml 2>&1
                $pcfgOk = ($LASTEXITCODE -eq 0)
                if ($pcfgOk -and (Test-Path -LiteralPath $tmpHtml)) {
                    # powercfg generates UTF-16 LE; use ReadAllText for auto BOM detection
                    $html = [System.IO.File]::ReadAllText($tmpHtml)
                    Remove-Item -LiteralPath $tmpHtml -Force -ErrorAction SilentlyContinue
                    if ($html) {
                        $dcPos = $html.IndexOf('DESIGN CAPACITY', [System.StringComparison]::OrdinalIgnoreCase)
                        if ($dcPos -ge 0) {
                            $window = $html.Substring($dcPos, [math]::Min(3000, $html.Length - $dcPos))
                            $mwhAll = [regex]::Matches($window, '(\d[\d,\.\s]*)\s*mWh')
                            if ($mwhAll.Count -ge 2) {
                                $dc = [int]($mwhAll[0].Groups[1].Value -replace '[^\d]', '')
                                $fc = [int]($mwhAll[1].Groups[1].Value -replace '[^\d]', '')
                                if ($dc -gt 0 -and $fc -gt 0) {
                                    $batteryInfo.DesignCapacityWh    = [math]::Round($dc / 1000, 1)
                                    $batteryInfo.FullChargeCapacityWh = [math]::Round($fc / 1000, 1)
                                    $batteryInfo.HealthPercent        = [math]::Round(($fc / $dc) * 100, 1)
                                }
                            }
                            # Also try to extract cycle count if not already set
                            if (-not $batteryInfo.CycleCount -and $mwhAll.Count -ge 2) {
                                $afterFc = $window.Substring($mwhAll[1].Index + $mwhAll[1].Length)
                                $cycleM = [regex]::Match($afterFc, '<td[^>]*>\s*(\d+)\s*</td>')
                                if ($cycleM.Success) { $batteryInfo.CycleCount = [int]$cycleM.Groups[1].Value }
                            }
                        }
                    }
                }
            }
            catch { }
        }
    }

    $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $mbInfo = [ordered]@{
        Manufacturer = if ($board -and $board.Manufacturer) { $board.Manufacturer.Trim() } else { 'N/A' }
        Model        = if ($board -and $board.Product) { $board.Product.Trim() } else { 'N/A' }
        BIOSVersion  = if ($bios -and $bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion } else { 'N/A' }
        BIOSDate     = if ($bios -and $bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'N/A' }
    }

    return [ordered]@{
        CPU         = $cpuInfo
        GPU         = $gpuList
        DIMMs       = $dimmList
        Battery     = $batteryInfo
        Motherboard = $mbInfo
    }
}

function Get-WinPulseTemperatures {
    [CmdletBinding()]
    param()

    $cpuTemp = $null
    $cpuSource = 'Unavailable'
    try {
        $thermal = Get-CimInstance -Namespace root\WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        if ($thermal) {
            $raw = ($thermal | Select-Object -First 1).CurrentTemperature
            $cpuTemp = [math]::Round(($raw - 2732) / 10, 1)
            $cpuSource = 'WMI ThermalZone'
        }
    }
    catch { }

    $diskTemps = @()
    if (Get-Command -Name Get-StorageReliabilityCounter -ErrorAction SilentlyContinue) {
        try {
            foreach ($pd in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                if ($rel -and $rel.Temperature) {
                    $diskTemps += [ordered]@{
                        DiskModel   = if ($pd.FriendlyName) { $pd.FriendlyName } else { 'Disk' }
                        TempCelsius = [int]$rel.Temperature
                        Source      = 'StorageReliabilityCounter'
                    }
                }
            }
        }
        catch { }
    }

    return [ordered]@{
        CPUTempCelsius = $cpuTemp
        CPUTempSource  = $cpuSource
        DiskTemps      = $diskTemps
        Note           = 'Native WMI temperature reading is limited. Use OpenHardwareMonitor for comprehensive temps.'
    }
}

function Get-WinPulseTPMStatus {
    [CmdletBinding()]
    param()

    $tpmResult = [ordered]@{ Present = $false; Enabled = $false; Version = 'N/A'; Manufacturer = 'N/A'; Win11Compatible = $false }
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmResult.Present = [bool]$tpm.TpmPresent
        $tpmResult.Enabled = [bool]$tpm.TpmReady
    }
    catch { }

    if ($tpmResult.Present) {
        try {
            $tpmWmi = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop
            if ($tpmWmi) {
                $spec = $tpmWmi.SpecVersion
                if ($spec) {
                    $ver = ($spec -split ',')[0].Trim()
                    $tpmResult.Version = $ver
                }
                if ($tpmWmi.ManufacturerIdTxt) {
                    $tpmResult.Manufacturer = $tpmWmi.ManufacturerIdTxt.Trim()
                }
            }
        }
        catch { }
    }

    $tpmResult.Win11Compatible = ($tpmResult.Version -like '2.*' -or $tpmResult.Version -eq '2.0')
    return $tpmResult
}

function Get-WinPulseDriverAnalysis {
    [CmdletBinding()]
    param()

    $errorCodeMap = @{
        1 = 'Not configured'; 3 = 'Driver corrupted'; 10 = 'Cannot start';
        12 = 'Not enough resources'; 14 = 'Restart required'; 16 = 'Not fully detected';
        22 = 'Disabled'; 24 = 'Not present'; 28 = 'Drivers not installed';
        29 = 'Resource disabled in BIOS'; 31 = 'Not working properly'; 32 = 'Driver disabled';
        33 = 'Cannot determine resources'; 34 = 'Cannot determine resources'; 43 = 'Windows stopped this device'; 44 = 'Shutdown signal received'
    }

    $problematic = @()
    $devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
    foreach ($dev in $devices) {
        $errDesc = if ($errorCodeMap.ContainsKey([int]$dev.ConfigManagerErrorCode)) { $errorCodeMap[[int]$dev.ConfigManagerErrorCode] } else { "Error code $($dev.ConfigManagerErrorCode)" }
        $problematic += [ordered]@{
            DeviceName       = if ($dev.Name) { $dev.Name } else { 'Unknown Device' }
            ErrorCode        = [int]$dev.ConfigManagerErrorCode
            ErrorDescription = $errDesc
        }
    }

    $unsigned = @()
    $recentlyChanged = @()
    try {
        $signedDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
        foreach ($drv in $signedDrivers) {
            if ($drv.IsSigned -eq $false -and $unsigned.Count -lt 50) {
                $unsigned += [ordered]@{
                    DeviceName     = if ($drv.DeviceName) { $drv.DeviceName } else { 'Unknown' }
                    DriverProvider = if ($drv.DriverProviderName) { $drv.DriverProviderName } else { 'N/A' }
                    InfName        = if ($drv.InfName) { $drv.InfName } else { 'N/A' }
                }
            }
            if ($drv.DriverDate -and $drv.DriverDate -gt (Get-Date).AddDays(-30) -and $recentlyChanged.Count -lt 20) {
                $recentlyChanged += [ordered]@{
                    DeviceName    = if ($drv.DeviceName) { $drv.DeviceName } else { 'Unknown' }
                    DriverVersion = if ($drv.DriverVersion) { $drv.DriverVersion } else { 'N/A' }
                    DriverDate    = $drv.DriverDate.ToString('yyyy-MM-dd')
                    DriverProvider = if ($drv.DriverProviderName) { $drv.DriverProviderName } else { 'N/A' }
                }
            }
        }
    }
    catch { }

    return [ordered]@{
        Problematic     = $problematic
        Unsigned        = $unsigned
        RecentlyChanged = $recentlyChanged
    }
}

function Get-WinPulseStartupAnalysis {
    [CmdletBinding()]
    param()

    $runKeys = @()
    $regPaths = @(
        @{ Location = 'HKLM Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        @{ Location = 'HKLM RunOnce'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' },
        @{ Location = 'HKCU Run'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        @{ Location = 'HKLM Run (32-bit)'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
    )
    foreach ($entry in $regPaths) {
        if (Test-Path $entry.Path) {
            $props = Get-ItemProperty -Path $entry.Path -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($name in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                    $runKeys += [ordered]@{
                        Location = $entry.Location
                        Name     = $name.Name
                        Command  = [string]$name.Value
                    }
                }
            }
        }
    }

    $startupItems = @()
    $startupPaths = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($sp in $startupPaths) {
        if (Test-Path $sp) {
            foreach ($item in (Get-ChildItem -Path $sp -ErrorAction SilentlyContinue)) {
                $startupItems += [ordered]@{
                    Name = $item.Name
                    Path = $item.FullName
                }
            }
        }
    }

    $logonTasks = @()
    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        foreach ($task in $allTasks) {
            if ($task.Triggers) {
                $hasLogon = $false
                foreach ($trigger in $task.Triggers) {
                    if ($trigger.CimClass -and $trigger.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') {
                        $hasLogon = $true
                        break
                    }
                }
                if ($hasLogon) {
                    $logonTasks += [ordered]@{
                        TaskName = $task.TaskName
                        TaskPath = $task.TaskPath
                        State    = [string]$task.State
                    }
                }
            }
        }
    }
    catch { }

    $failedServices = @()
    try {
        $autoStopped = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
        foreach ($svc in $autoStopped) {
            $failedServices += [ordered]@{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                Status      = [string]$svc.Status
            }
        }
    }
    catch { }

    $bootTime = $null
    $bootDurationMs = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $bootTime = $os.LastBootUpTime }
        $bootEvent = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($bootEvent -and $bootEvent.Properties.Count -gt 0) {
            $bootDurationMs = [int]$bootEvent.Properties[0].Value
        }
    }
    catch { }

    return [ordered]@{
        RunKeyItems        = $runKeys
        StartupFolderItems = $startupItems
        LogonScheduledTasks = $logonTasks
        FailedAutoServices = $failedServices
        LastBootTime       = $bootTime
        BootDurationMs     = $bootDurationMs
    }
}

function Get-WinPulseUserAccounts {
    [CmdletBinding()]
    param()

    $users = @()
    $adminNames = @()
    try {
        $adminMembers = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
        $adminNames = @($adminMembers | ForEach-Object { ($_.Name -split '\\')[-1] })
    }
    catch { }

    try {
        foreach ($u in (Get-LocalUser -ErrorAction SilentlyContinue)) {
            $users += [ordered]@{
                Name            = $u.Name
                Enabled         = [bool]$u.Enabled
                IsAdmin         = ($u.Name -in $adminNames)
                LastLogon       = if ($u.LastLogon) { $u.LastLogon.ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
                PasswordExpires = if ($u.PasswordExpires) { $u.PasswordExpires.ToString('yyyy-MM-dd') } else { 'Never' }
                PasswordLastSet = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { 'N/A' }
            }
        }
    }
    catch { }

    $profileCount = 0
    try {
        $excludeNames = @('Public', 'Default', 'Default User', 'All Users')
        $profileCount = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $excludeNames }).Count
    }
    catch { }

    return [ordered]@{
        Users        = $users
        ProfileCount = $profileCount
    }
}

function Get-WinPulseNetworkDetail {
    [CmdletBinding()]
    param()

    $adapters = @()
    try {
        foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $adapters += [ordered]@{
                Name      = $a.Name
                Status    = [string]$a.Status
                Speed     = if ($a.LinkSpeed) { $a.LinkSpeed } else { 'N/A' }
                MAC       = if ($a.MacAddress) { $a.MacAddress } else { 'N/A' }
                MediaType = if ($a.MediaType) { $a.MediaType } else { 'N/A' }
            }
        }
    }
    catch { }

    $wifi = $null
    try {
        $wlanOutput = & netsh wlan show interfaces 2>$null
        if ($wlanOutput) {
            $ssid = ($wlanOutput | Select-String '^\s+SSID\s+:\s+(.+)$' | Select-Object -First 1)
            $signal = ($wlanOutput | Select-String '^\s+Signal\s+:\s+(\d+)%' | Select-Object -First 1)
            $channel = ($wlanOutput | Select-String '^\s+Channel\s+:\s+(\d+)' | Select-Object -First 1)
            $band = ($wlanOutput | Select-String '^\s+Band\s+:\s+(.+)$' | Select-Object -First 1)
            if ($ssid) {
                $wifi = [ordered]@{
                    SSID          = $ssid.Matches[0].Groups[1].Value.Trim()
                    SignalPercent = if ($signal) { [int]$signal.Matches[0].Groups[1].Value } else { $null }
                    Channel       = if ($channel) { [int]$channel.Matches[0].Groups[1].Value } else { $null }
                    Band          = if ($band) { $band.Matches[0].Groups[1].Value.Trim() } else { 'N/A' }
                }
            }
        }
    }
    catch { }

    $listeningPorts = @()
    try {
        $tcpConns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -First 25
        foreach ($conn in $tcpConns) {
            $procName = 'N/A'
            try {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) { $procName = $proc.ProcessName }
            }
            catch { }
            $listeningPorts += [ordered]@{
                LocalAddress = [string]$conn.LocalAddress
                Port         = [int]$conn.LocalPort
                ProcessName  = $procName
                PID          = [int]$conn.OwningProcess
            }
        }
    }
    catch { }

    $smbShares = @()
    try {
        foreach ($share in (Get-SmbShare -ErrorAction SilentlyContinue)) {
            $smbShares += [ordered]@{
                Name        = $share.Name
                Path        = if ($share.Path) { $share.Path } else { 'N/A' }
                Description = if ($share.Description) { $share.Description } else { '' }
            }
        }
    }
    catch { }

    $vpnProfiles = @()
    try {
        foreach ($vpn in (Get-VpnConnection -ErrorAction SilentlyContinue)) {
            $vpnProfiles += [ordered]@{
                Name             = $vpn.Name
                ServerAddress    = if ($vpn.ServerAddress) { $vpn.ServerAddress } else { 'N/A' }
                TunnelType       = if ($vpn.TunnelType) { [string]$vpn.TunnelType } else { 'N/A' }
                ConnectionStatus = [string]$vpn.ConnectionStatus
            }
        }
    }
    catch { }

    $gwReachable = $false
    try {
        $gw = (Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
        if ($gw) {
            $gwReachable = [bool](Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue)
        }
    }
    catch { }

    return [ordered]@{
        Adapters         = $adapters
        WiFi             = $wifi
        ListeningPorts   = $listeningPorts
        SMBShares        = $smbShares
        VPNProfiles      = $vpnProfiles
        GatewayReachable = $gwReachable
    }
}

function Get-WinPulseSoftwareInventory {
    [CmdletBinding()]
    param()

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $seen = @{}
    $items = @()
    foreach ($rp in $regPaths) {
        $entries = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            $dn = if ($entry.PSObject.Properties['DisplayName']) { $entry.PSObject.Properties['DisplayName'].Value } else { $null }
            if (-not $dn) { continue }
            $dv = if ($entry.PSObject.Properties['DisplayVersion']) { $entry.PSObject.Properties['DisplayVersion'].Value } else { $null }
            $pub = if ($entry.PSObject.Properties['Publisher']) { $entry.PSObject.Properties['Publisher'].Value } else { $null }
            $id = if ($entry.PSObject.Properties['InstallDate']) { $entry.PSObject.Properties['InstallDate'].Value } else { $null }
            $key = '{0}|{1}' -f $dn, $dv
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $items += [ordered]@{
                Name        = $dn
                Version     = if ($dv) { $dv } else { 'N/A' }
                Publisher   = if ($pub) { $pub } else { 'N/A' }
                InstallDate = if ($id) { $id } else { 'N/A' }
            }
        }
    }

    $items = @($items | Sort-Object { $_.Name })

    return [ordered]@{
        Items = $items
        Count = $items.Count
    }
}

function Get-WinPulsePrinterStatus {
    [CmdletBinding()]
    param()

    $installed = @()
    $defaultPrinter = 'N/A'
    $stuckJobs = @()

    if (-not (Get-Command -Name Get-Printer -ErrorAction SilentlyContinue)) {
        return [ordered]@{ Installed = @(); DefaultPrinter = 'N/A'; StuckJobs = @() }
    }

    try {
        $printers = Get-Printer -ErrorAction SilentlyContinue
        foreach ($p in $printers) {
            $isDefault = $false
            if ($p.PSObject.Properties['Default']) { $isDefault = [bool]$p.Default }
            if ($isDefault) { $defaultPrinter = $p.Name }
            $installed += [ordered]@{
                Name       = $p.Name
                PortName   = if ($p.PortName) { $p.PortName } else { 'N/A' }
                DriverName = if ($p.DriverName) { $p.DriverName } else { 'N/A' }
                Shared     = [bool]$p.Shared
                Default    = $isDefault
            }
        }
    }
    catch { }

    try {
        foreach ($p in $printers) {
            $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
            foreach ($job in $jobs) {
                $stuckJobs += [ordered]@{
                    PrinterName   = $p.Name
                    DocumentName  = if ($job.DocumentName) { $job.DocumentName } else { 'N/A' }
                    JobStatus     = [string]$job.JobStatus
                    SubmittedTime = if ($job.SubmittedTime) { $job.SubmittedTime.ToString('yyyy-MM-dd HH:mm') } else { 'N/A' }
                }
            }
        }
    }
    catch { }

    return [ordered]@{
        Installed      = $installed
        DefaultPrinter = $defaultPrinter
        StuckJobs      = $stuckJobs
    }
}

function Get-WinPulseLicenseInfo {
    [CmdletBinding()]
    param()

    $licResult = [ordered]@{
        ActivationStatus = 'Unknown'
        LicenseType      = 'Unknown'
        PartialProductKey = 'N/A'
        ExpiryDate       = $null
        ProductName      = 'N/A'
    }

    try {
        # Filter server-side: ApplicationID is the Windows OS licensing family,
        # and PartialProductKey IS NOT NULL narrows to the installed product.
        # Without this WQL filter, SoftwareLicensingProduct enumerates hundreds
        # of SKU entries and takes ~10s; the filter brings it under a second.
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction SilentlyContinue |
            Where-Object { $_.PartialProductKey } |
            Select-Object -First 1

        if ($lic) {
            $statusMap = @{ 0 = 'Unlicensed'; 1 = 'Activated'; 2 = 'OOB Grace'; 3 = 'OOT Grace'; 4 = 'Non-Genuine'; 5 = 'Notification'; 6 = 'Extended Grace' }
            $licResult.ActivationStatus = if ($statusMap.ContainsKey([int]$lic.LicenseStatus)) { $statusMap[[int]$lic.LicenseStatus] } else { "Status $($lic.LicenseStatus)" }
            $licResult.PartialProductKey = $lic.PartialProductKey
            $licResult.ProductName = if ($lic.Name) { $lic.Name } else { 'N/A' }

            $desc = [string]$lic.Description
            if ($desc -match 'OEM') { $licResult.LicenseType = 'OEM' }
            elseif ($desc -match 'RETAIL') { $licResult.LicenseType = 'Retail' }
            elseif ($desc -match 'KMS') { $licResult.LicenseType = 'Volume/KMS' }
            elseif ($desc -match 'MAK') { $licResult.LicenseType = 'Volume/MAK' }
            elseif ($desc -match 'VOLUME') { $licResult.LicenseType = 'Volume' }

            if ($lic.GracePeriodRemaining -and $lic.GracePeriodRemaining -gt 0) {
                $licResult.ExpiryDate = (Get-Date).AddMinutes($lic.GracePeriodRemaining).ToString('yyyy-MM-dd')
            }
        }
    }
    catch { }

    return $licResult
}

function Get-WinPulseScheduledTaskAnalysis {
    [CmdletBinding()]
    param()

    $nonMicrosoft = @()
    $failed = @()
    $runAsSystem = @()

    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        $nonMsTasks = @($allTasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })

        foreach ($task in $nonMsTasks) {
            $nonMicrosoft += [ordered]@{
                TaskName    = $task.TaskName
                TaskPath    = $task.TaskPath
                State       = [string]$task.State
                Author      = if ($task.Author) { $task.Author } else { 'N/A' }
                LastRunTime = 'N/A'
            }

            try {
                $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                if ($info) {
                    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) {
                        $nonMicrosoft[-1].LastRunTime = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm')
                    }
                    if ($info.LastTaskResult -ne 0) {
                        $failed += [ordered]@{
                            TaskName    = $task.TaskName
                            TaskPath    = $task.TaskPath
                            LastResult  = '0x{0:X8}' -f $info.LastTaskResult
                            LastRunTime = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'N/A' }
                        }
                    }
                }
            }
            catch { }

            $userId = $null
            if ($task.Principal) { $userId = $task.Principal.UserId }
            if ($userId -and ($userId -match 'SYSTEM' -or $userId -eq 'S-1-5-18')) {
                $runAsSystem += [ordered]@{
                    TaskName = $task.TaskName
                    TaskPath = $task.TaskPath
                    State    = [string]$task.State
                }
            }
        }
    }
    catch { }

    return [ordered]@{
        NonMicrosoft = $nonMicrosoft
        Failed       = $failed
        RunAsSystem  = $runAsSystem
    }
}

function Get-WinPulseVirtualizationInfo {
    [CmdletBinding()]
    param()

    $isVM = $false
    $vmPlatform = 'None'
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) {
            $model = [string]$cs.Model
            $manufacturer = [string]$cs.Manufacturer
            if ($model -match 'Virtual Machine|Hyper-V') { $isVM = $true; $vmPlatform = 'Hyper-V' }
            elseif ($model -match 'VMware' -or $manufacturer -match 'VMware') { $isVM = $true; $vmPlatform = 'VMware' }
            elseif ($model -match 'VirtualBox' -or $manufacturer -match 'innotek') { $isVM = $true; $vmPlatform = 'VirtualBox' }
            elseif ($model -match 'KVM' -or $manufacturer -match 'QEMU') { $isVM = $true; $vmPlatform = 'KVM/QEMU' }
            elseif ($cs.HypervisorPresent) { $isVM = $true; $vmPlatform = 'Unknown Hypervisor' }
        }
    }
    catch { }

    $hyperVEnabled = $null
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
        if ($feature) { $hyperVEnabled = ($feature.State -eq 'Enabled') }
    }
    catch { }

    $wslDistros = @()
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        try {
            $wslOutput = & wsl --list --quiet 2>$null
            if ($wslOutput) {
                $wslDistros = @($wslOutput | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() -replace '\x00', '' })
            }
        }
        catch { }
    }

    return [ordered]@{
        IsVM              = $isVM
        VMPlatform        = $vmPlatform
        HyperVEnabled     = $hyperVEnabled
        WSLDistributions  = $wslDistros
    }
}

function Invoke-CoreScan {
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        GeneratedAt = (Get-Date)
        System      = [ordered]@{
            Hostname = $env:COMPUTERNAME
            Model = 'N/A'
            Serial = 'N/A'
            WindowsVersion = 'N/A'
            Uptime = 'N/A'
            DomainJoined = $false
            Domain = 'Unknown'
            Firmware = 'Unknown'
        }
        Hardware    = [ordered]@{
            Ram = [ordered]@{
                Total = '0 B'
                Free = '0 B'
                Used = '0 B'
                UsedPercent = 0
            }
            Disks = @()
            SmartHealthy = $true
            CpuLoadPercent = $null
        }
        Security    = [ordered]@{
            Defender = [ordered]@{
                RealTimeProtection = $false
                SignaturesUpToDate = $false
            }
            Antivirus = [ordered]@{
                Products = @()
                ThirdPartyCount = 0
                EffectiveRealtimeProtection = $false
            }
            BitLocker = @()
            FirewallEnabled = $false
            SecureBootState = 'Unknown'
        }
        Health      = [ordered]@{
            BsodRecentCount = 0
            WindowsUpdateErrorCount24Hours = 0
            WindowsUpdateRecentErrors = @()
            WindowsUpdateCategoryCounts = [ordered]@{
                StoreApps = 0
                UpdateService = 0
                Network = 0
                Servicing = 0
                AccessDenied = 0
                General = 0
            }
            CriticalLast24Hours = 0
            PendingReboot = $false
        }
        Network     = [ordered]@{
            IPv4 = $null
            Gateway = $null
            DnsServers = @()
            Internet = $false
        }
        HardwareDetail = $null
        Temperatures   = $null
        TPM            = $null
        Drivers        = $null
        Startup        = $null
        UserAccounts   = $null
        NetworkDetail  = $null
        Software       = $null
        Printers       = $null
        License        = $null
        ScheduledTasks = $null
        Virtualization = $null
        DetailScanned  = $false
        Errors      = @()
    }

    # Reused across the System and Hardware collectors so Win32_OperatingSystem
    # is queried only once.
    $os = $null

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem
        $bios = Get-CimInstance -ClassName Win32_BIOS
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $firmwareMode = Get-WinPulseFirmwareMode
        $domainJoined = [bool]$computer.PartOfDomain
        $domainLabel = if ($domainJoined) { [string]$computer.Domain } else { 'Workgroup' }

        $uptime = (Get-Date) - $os.LastBootUpTime
        $result.System = [ordered]@{
            Hostname = $env:COMPUTERNAME
            Model = $computer.Model
            Serial = $bios.SerialNumber
            WindowsVersion = ('{0} ({1})' -f $os.Caption, $os.BuildNumber)
            Uptime = ('{0}d {1}h {2}m' -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes)
            DomainJoined = $domainJoined
            Domain = $domainLabel
            Firmware = $firmwareMode
        }
    }
    catch {
        $result.Errors += "SYSTEM scan failed: $($_.Exception.Message)"
    }

    try {
        if (-not $os) { $os = Get-CimInstance -ClassName Win32_OperatingSystem }
        $totalMemory = [double]$os.TotalVisibleMemorySize * 1KB
        $freeMemory = [double]$os.FreePhysicalMemory * 1KB
        $usedMemory = $totalMemory - $freeMemory
        $ramPercent = if ($totalMemory -gt 0) { [math]::Round(($usedMemory / $totalMemory) * 100, 2) } else { 0 }
        $cpuLoad = $null
        try {
            $cpuObj = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cpuObj -and $cpuObj.PSObject.Properties['LoadPercentage'] -and $null -ne $cpuObj.LoadPercentage) {
                $cpuLoad = [int]$cpuObj.LoadPercentage
            }
        }
        catch { }

        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
        $diskStates = foreach ($disk in $disks) {
            $usedPct = if ($disk.Size -gt 0) { [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 2) } else { 0 }
            [pscustomobject]@{
                Drive = $disk.DeviceID
                Size = ConvertTo-ReadableSize -bytes $disk.Size
                Free = ConvertTo-ReadableSize -bytes $disk.FreeSpace
                UsedPercent = $usedPct
            }
        }

        $smartRaw = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
        $smartHealthy = $true
        if ($smartRaw) {
            foreach ($item in $smartRaw) {
                if ($item.PredictFailure) {
                    $smartHealthy = $false
                    break
                }
            }
        }

        $result.Hardware = [ordered]@{
            Ram = [ordered]@{
                Total = ConvertTo-ReadableSize -bytes $totalMemory
                Free = ConvertTo-ReadableSize -bytes $freeMemory
                Used = ConvertTo-ReadableSize -bytes $usedMemory
                UsedPercent = $ramPercent
            }
            Disks = $diskStates
            SmartHealthy = $smartHealthy
            CpuLoadPercent = $cpuLoad
        }
    }
    catch {
        $result.Errors += "HARDWARE scan failed: $($_.Exception.Message)"
    }

    try {
        $defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $avProducts = @(Get-WinPulseAntivirusProducts | Where-Object { $_ -and $_.PSObject.Properties['Name'] })
        $thirdPartyCount = @($avProducts | Where-Object { -not $_.IsMicrosoft }).Count
        $effectiveRt = $false
        if ($thirdPartyCount -gt 0) {
            $effectiveRt = $true
        }
        elseif ($defenderStatus) {
            $effectiveRt = [bool]$defenderStatus.RealTimeProtectionEnabled
        }

        $bitlockerStatus = @()
        foreach ($volume in (Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            $bitlockerStatus += [pscustomobject]@{
                MountPoint = $volume.MountPoint
                ProtectionStatus = [string]$volume.ProtectionStatus
                EncryptionPercentage = $volume.EncryptionPercentage
            }
        }

        $firewallProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $firewallEnabled = $false
        if ($firewallProfiles) {
            $firewallEnabled = -not ($firewallProfiles.Enabled -contains $false)
        }

        $secureBootState = (Get-WinPulseSecureBootState -firmwaremode $result.System.Firmware)
        if ($result.System.Firmware -eq 'Unknown' -and ($secureBootState -eq 'On' -or $secureBootState -eq 'Off')) {
            $result.System.Firmware = 'UEFI'
        }

        $result.Security = [ordered]@{
            Defender = [ordered]@{
                RealTimeProtection = if ($defenderStatus) { [bool]$defenderStatus.RealTimeProtectionEnabled } else { $false }
                SignaturesUpToDate = if ($defenderStatus) { [bool](-not $defenderStatus.AntispywareSignatureAge -and -not $defenderStatus.AntivirusSignatureAge) } else { $false }
            }
            Antivirus = [ordered]@{
                Products = $avProducts
                ThirdPartyCount = $thirdPartyCount
                EffectiveRealtimeProtection = $effectiveRt
            }
            BitLocker = $bitlockerStatus
            FirewallEnabled = $firewallEnabled
            SecureBootState = $secureBootState
        }
    }
    catch {
        $result.Errors += "SECURITY scan failed: $($_.Exception.Message)"
    }

    try {
        $bsodEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue)
        $wuErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Level = 2; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue)
        $critical24h = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue)
        $wuRecent = @()
        $wuCategoryCounts = [ordered]@{
            StoreApps = 0
            UpdateService = 0
            Network = 0
            Servicing = 0
            AccessDenied = 0
            General = 0
        }

        foreach ($event in ($wuErrors | Sort-Object TimeCreated -Descending)) {
            $message = ''
            if ($event.Message) {
                $message = ($event.Message -replace '\s+', ' ').Trim()
            }
            if ($message.Length -gt 170) {
                $message = $message.Substring(0, 170) + '...'
            }

            $code = 'N/A'
            $match = [regex]::Match($message, '0x[0-9A-Fa-f]{8}')
            if ($match.Success) {
                $code = $match.Value.ToUpperInvariant()
            }
            $category = Get-WinPulseWuErrorCategory -code $code -message $message
            if ($wuCategoryCounts.Contains($category)) {
                $wuCategoryCounts[$category] = [int]$wuCategoryCounts[$category] + 1
            }

            if ($wuRecent.Count -lt 5) {
                $wuRecent += [pscustomobject]@{
                    Time = $event.TimeCreated
                    EventId = $event.Id
                    Code = $code
                    Category = $category
                    Message = $message
                }
            }
        }

        $result.Health = [ordered]@{
            BsodRecentCount = $bsodEvents.Count
            WindowsUpdateErrorCount24Hours = $wuErrors.Count
            WindowsUpdateRecentErrors = $wuRecent
            WindowsUpdateCategoryCounts = $wuCategoryCounts
            CriticalLast24Hours = $critical24h.Count
            PendingReboot = (Test-WinPulsePendingReboot)
        }
    }
    catch {
        $result.Errors += "HEALTH scan failed: $($_.Exception.Message)"
    }

    try {
        $ipCfg = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        $dns = if ($ipCfg) { @($ipCfg.DNSServer.ServerAddresses) } else { @() }

        # Bounded ping (800 ms) so an offline machine does not stall startup on
        # the default Test-Connection timeout.
        $internet = $false
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send('1.1.1.1', 800)
            $internet = ($reply -and $reply.Status -eq 'Success')
        }
        catch {
            $internet = $false
        }

        $result.Network = [ordered]@{
            IPv4 = if ($ipCfg) { $ipCfg.IPv4Address.IPAddress } else { $null }
            Gateway = if ($ipCfg) { $ipCfg.IPv4DefaultGateway.NextHop } else { $null }
            DnsServers = $dns
            Internet = [bool]$internet
        }
    }
    catch {
        $result.Errors += "NETWORK scan failed: $($_.Exception.Message)"
    }

    # -- Extended diagnostic sections -----------------------------------------
    Write-Host '  Scanning hardware details...' -ForegroundColor Gray -NoNewline
    try { $result.HardwareDetail = Get-WinPulseHardwareDetail }
    catch { $result.Errors += "HW DETAIL: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    Write-Host '  Scanning temperatures...' -ForegroundColor Gray -NoNewline
    try { $result.Temperatures = Get-WinPulseTemperatures }
    catch { $result.Errors += "TEMPERATURES: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    Write-Host '  Scanning TPM...' -ForegroundColor Gray -NoNewline
    try { $result.TPM = Get-WinPulseTPMStatus }
    catch { $result.Errors += "TPM: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    Write-Host '  Scanning drivers (this may take a moment)...' -ForegroundColor Gray -NoNewline
    try { $result.Drivers = Get-WinPulseDriverAnalysis }
    catch { $result.Errors += "DRIVERS: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    Write-Host '  Scanning startup items...' -ForegroundColor Gray -NoNewline
    try { $result.Startup = Get-WinPulseStartupAnalysis }
    catch { $result.Errors += "STARTUP: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    Write-Host '  Scanning printers...' -ForegroundColor Gray -NoNewline
    try { $result.Printers = Get-WinPulsePrinterStatus }
    catch { $result.Errors += "PRINTERS: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    Write-Host '  Scanning license...' -ForegroundColor Gray -NoNewline
    try { $result.License = Get-WinPulseLicenseInfo }
    catch { $result.Errors += "LICENSE: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor Gray

    # Detail-only collectors (installed software, scheduled tasks, user
    # accounts, network detail, virtualization) are NOT needed for the dashboard
    # or the triage findings, so they are deferred to Complete-WinPulseDetailScan
    # and loaded lazily the first time the full report is generated. This keeps
    # startup fast.

    return [pscustomobject]$result
}

function Complete-WinPulseDetailScan {
    # Lazily fills the detail-only scan sections (software inventory, scheduled
    # tasks, user accounts, network detail, virtualization). Idempotent: it
    # mutates the passed scan object in place and returns early once done, so it
    # is cheap to call from every consumer that needs the full data.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    if ($scan.DetailScanned) { return $scan }

    Write-Host '  Loading full details (software, tasks, accounts)...' -ForegroundColor Gray -NoNewline
    try { $scan.UserAccounts = Get-WinPulseUserAccounts }
    catch { $scan.Errors += "USERS: $($_.Exception.Message)" }
    try { $scan.NetworkDetail = Get-WinPulseNetworkDetail }
    catch { $scan.Errors += "NETWORK DETAIL: $($_.Exception.Message)" }
    try { $scan.Software = Get-WinPulseSoftwareInventory }
    catch { $scan.Errors += "SOFTWARE: $($_.Exception.Message)" }
    try { $scan.ScheduledTasks = Get-WinPulseScheduledTaskAnalysis }
    catch { $scan.Errors += "SCHEDULED TASKS: $($_.Exception.Message)" }
    try { $scan.Virtualization = Get-WinPulseVirtualizationInfo }
    catch { $scan.Errors += "VIRTUALIZATION: $($_.Exception.Message)" }
    $scan.DetailScanned = $true
    Write-Host ' done' -ForegroundColor Gray

    return $scan
}

function Write-Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$label,

        [Parameter(Mandatory = $true)]
        [string]$value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'Warning', 'Critical', 'Info')]
        [string]$state
    )

    $meta = switch ($state) {
        'OK' { @{ Color = 'Green'; Badge = '[OK]' } }
        'Warning' { @{ Color = 'Yellow'; Badge = '[WARN]' } }
        'Critical' { @{ Color = 'Red'; Badge = '[CRIT]' } }
        default { @{ Color = 'Cyan'; Badge = '[INFO]' } }
    }

    Write-Host ('{0} {1,-12} {2}' -f $meta.Badge, $label, $value) -ForegroundColor $meta.Color
}

function Get-WinPulseBoxWidth {
    # Box width for the TUI. Defaults to the historical 88. On a real console
    # narrower than 90 columns it shrinks to fit (floor 62) so the layout does
    # not wrap; on any window >= 90 columns it returns exactly 88 (unchanged),
    # and it falls back to 88 in non-interactive/redirected hosts.
    [CmdletBinding()]
    param()

    try {
        $cols = [Console]::WindowWidth
        if ($cols -ge 62 -and $cols -lt 90) {
            return ($cols - 2)
        }
    }
    catch { }
    return 88
}

function Write-WinPulseHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$title
    )

    $w = Get-WinPulseBoxWidth
    Write-Host ''
    Write-Host ('  {0}{1}{2}' -f ([char]0x2554), ([string][char]0x2550 * ($w - 2)), ([char]0x2557)) -ForegroundColor Yellow
    Write-Host -NoNewline ('  {0} ' -f ([char]0x2551)) -ForegroundColor Yellow
    Write-Host -NoNewline ('{0}' -f $title.PadRight($w - 4)) -ForegroundColor Cyan
    Write-Host (' {0}' -f ([char]0x2551)) -ForegroundColor Yellow
    Write-Host ('  {0}{1}{2}' -f ([char]0x255A), ([string][char]0x2550 * ($w - 2)), ([char]0x255D)) -ForegroundColor Yellow
}

function Select-WinPulseMenuItem {
    [CmdletBinding()]
    param(
        [string]$Title = 'Menu',
        [Parameter(Mandatory = $true)]
        [array]$Items
    )

    # Items: @( @{Label='text'; Key='D'; Hint='optional'; Separator=$false; Color='White'} )
    # Returns: Key of selected item, or $null on Escape

    $selectableIdx = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i]['Separator']) { $selectableIdx += $i }
    }
    if ($selectableIdx.Count -eq 0) { return $null }

    # Check interactive capability
    $interactive = $true
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { $interactive = $false }

    $w = Get-WinPulseBoxWidth
    $hLine = [string][char]0x2550 * ($w - 2)
    $vLine = [char]0x2551

    if (-not $interactive) {
        Write-WinPulseHeader -title $Title
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($Items[$i]['Separator']) { Write-Host ''; continue }
            Write-Host ('  [{0}] {1}' -f $Items[$i]['Key'], $Items[$i]['Label']) -ForegroundColor White
        }
        $ch = (Read-Host '  Select').Trim().ToUpperInvariant()
        return $ch
    }

    [Console]::CursorVisible = $false
    $sel = 0
    # Required frame height: top border + items + bottom border + help line
    $frameHeight = $Items.Count + 3
    try {
        $startY = [Console]::CursorTop
        # Scroll safeguard: if frame doesn't fit below current cursor, clear screen
        if (($startY + $frameHeight) -ge ([Console]::BufferHeight - 1)) {
            Clear-Host
            $startY = 0
        }
        $lastLineCount = 0

        while ($true) {
            if ($lastLineCount -gt 0) {
                [Console]::SetCursorPosition(0, $startY)
                $blankWidth = [math]::Min($w + 4, [Console]::BufferWidth - 1)
                if ($blankWidth -lt 1) { $blankWidth = 1 }
                $blank = ' ' * $blankWidth
                for ($c = 0; $c -lt $lastLineCount; $c++) { Write-Host $blank }
                [Console]::SetCursorPosition(0, $startY)
            }
            $drawnLines = 0

            # Top border
            Write-Host ('  {0}{1} {2} {3}{4}' -f ([char]0x2554), ([string][char]0x2550 * 2), $Title, ([string][char]0x2550 * [math]::Max(1, $w - $Title.Length - 6)), ([char]0x2557)) -ForegroundColor Yellow
            $drawnLines++

            for ($i = 0; $i -lt $Items.Count; $i++) {
                $item = $Items[$i]

                if ($item['Separator']) {
                    Write-Host ('  {0}{1}{2}' -f $vLine, (' ' * ($w - 2)), $vLine) -ForegroundColor Yellow
                    $drawnLines++
                    continue
                }

                $isSelected = ($selectableIdx[$sel] -eq $i)
                $pointer = if ($isSelected) { '>' } else { ' ' }
                $keyTag = if ($item['Key']) { '[{0}]' -f $item['Key'] } else { '   ' }
                $hint = if ($item['Hint']) { $item['Hint'] } else { '' }
                $color = if ($item['Color']) { $item['Color'] } else { 'White' }

                $left = ' {0} {1} {2}' -f $pointer, $keyTag, $item['Label']
                $avail = $w - 4
                $rightSpace = $avail - $left.Length
                if ($rightSpace -lt 0) { $left = $left.Substring(0, $avail); $rightSpace = 0 }
                $line = if ($hint -and $rightSpace -gt ($hint.Length + 2)) {
                    $left + (' ' * ($rightSpace - $hint.Length)) + $hint
                }
                else {
                    $left + (' ' * $rightSpace)
                }

                Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor Yellow
                if ($isSelected) {
                    Write-Host -NoNewline $line -ForegroundColor Black -BackgroundColor Yellow
                }
                else {
                    Write-Host -NoNewline $line -ForegroundColor Gray
                }
                Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
                $drawnLines++
            }

            # Bottom border
            Write-Host ('  {0}{1}{2}' -f ([char]0x255A), $hLine, ([char]0x255D)) -ForegroundColor Yellow
            $drawnLines++
            # Help bar
            $helpText = '  {0}/{1} Navigate  Enter Select  Esc Back' -f ([char]0x2191), ([char]0x2193)
            Write-Host ($helpText + (' ' * [math]::Max(0, $w - $helpText.Length + 2))) -ForegroundColor Gray
            $drawnLines++

            $lastLineCount = $drawnLines

            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

            switch ($k.VirtualKeyCode) {
                38 { $sel = if ($sel -gt 0) { $sel - 1 } else { $selectableIdx.Count - 1 } }
                40 { $sel = if ($sel -lt $selectableIdx.Count - 1) { $sel + 1 } else { 0 } }
                13 { return $Items[$selectableIdx[$sel]]['Key'] }
                27 { return $null }
                default {
                    $ch = [string]$k.Character
                    if ($ch) {
                        $ch = $ch.ToUpperInvariant()
                        $match = $Items | Where-Object { $_['Key'] -and $_['Key'].ToUpperInvariant() -eq $ch -and -not $_['Separator'] }
                        if ($match) { return $ch.ToUpperInvariant() }
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Select-WinPulseMultiMenuItem {
    # Arrow-key multi-select menu. Space toggles, Enter confirms, Esc cancels.
    # Returns array of selected Keys (empty array = cancelled/none).
    [CmdletBinding()]
    param(
        [string]$Title = 'Select',
        [Parameter(Mandatory = $true)]
        [array]$Items
    )

    $selectableIdx = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i]['Separator']) { $selectableIdx += $i }
    }
    if ($selectableIdx.Count -eq 0) { return @() }

    $checked = @{}
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not $Items[$i]['Separator'] -and $Items[$i]['Selected']) { $checked[$i] = $true }
    }
    $interactive = $true
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { $interactive = $false }

    if (-not $interactive) {
        Write-WinPulseHeader -title $Title
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($Items[$i]['Separator']) { continue }
            Write-Host ('  [{0}] {1}' -f ($i + 1), $Items[$i]['Label'])
        }
        $result = @()
        foreach ($part in ((Read-Host '  Select (e.g. 1,3)') -split ',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
                $result += $Items[$n - 1]['Key']
            }
        }
        return $result
    }

    $w = Get-WinPulseBoxWidth
    $hLine = [string][char]0x2550 * ($w - 2)
    $vLine = [char]0x2551
    $sel = 0
    $viewTop = 0   # first visible item index in $Items

    [Console]::CursorVisible = $false
    try {
        Clear-Host
        $startY = 0
        $lastLineCount = 0

        while ($true) {
            # Available lines for items: terminal height minus top-border, bottom-border, help, one spare
            $maxViewport = [math]::Max(1, [Console]::WindowHeight - 4)

            # Keep active item visible: find its position among all items
            $activeItemIdx = $selectableIdx[$sel]
            # Scroll viewTop so activeItemIdx stays within [viewTop, viewTop+maxViewport)
            if ($activeItemIdx -lt $viewTop) { $viewTop = $activeItemIdx }
            if ($activeItemIdx -ge ($viewTop + $maxViewport)) { $viewTop = $activeItemIdx - $maxViewport + 1 }

            # Clear previous frame
            if ($lastLineCount -gt 0) {
                [Console]::SetCursorPosition(0, $startY)
                $blankWidth = [math]::Min($w + 4, [Console]::BufferWidth - 1)
                if ($blankWidth -lt 1) { $blankWidth = 1 }
                $blank = ' ' * $blankWidth
                for ($c = 0; $c -lt $lastLineCount; $c++) { Write-Host $blank }
                [Console]::SetCursorPosition(0, $startY)
            }
            $drawnLines = 0

            # Top border + scroll indicator
            $scrollInfo = if ($Items.Count -gt $maxViewport) { ' {0}/{1} ' -f ($sel + 1), $selectableIdx.Count } else { '' }
            $titleFull = if ($scrollInfo) { '{0}  {1}' -f $Title, $scrollInfo } else { $Title }
            Write-Host ('  {0}{1} {2} {3}{4}' -f ([char]0x2554), ([string][char]0x2550 * 2), $titleFull, ([string][char]0x2550 * [math]::Max(1, $w - $titleFull.Length - 6)), ([char]0x2557)) -ForegroundColor Yellow
            $drawnLines++

            # Render only items in viewport window
            $rendered = 0
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ($rendered -ge $maxViewport) { break }
                if ($i -lt $viewTop) { continue }
                $item = $Items[$i]

                if ($item['Separator']) {
                    if ($item['Label']) {
                        $catLabel = '  ' + $item['Label']
                        $catPad = $w - 2 - $catLabel.Length
                        if ($catPad -lt 0) { $catPad = 0 }
                        Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor Yellow
                        Write-Host -NoNewline ($catLabel + (' ' * $catPad)) -ForegroundColor Yellow
                        Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
                    } else {
                        Write-Host ('  {0}{1}{2}' -f $vLine, (' ' * ($w - 2)), $vLine) -ForegroundColor Yellow
                    }
                    $drawnLines++
                    $rendered++
                    continue
                }

                $isActive  = ($selectableIdx[$sel] -eq $i)
                $isChecked = $checked.ContainsKey($i)
                $pointer   = if ($isActive) { '>' } else { ' ' }
                $box       = if ($isChecked) { '[x]' } else { '[ ]' }
                $hint      = if ($item['Hint']) { $item['Hint'] } else { '' }
                $color     = if ($isChecked) { 'Cyan' } else { 'Gray' }

                $left = ' {0} {1} {2}' -f $pointer, $box, $item['Label']
                $avail = $w - 4
                $rightSpace = $avail - $left.Length
                if ($rightSpace -lt 0) { $left = $left.Substring(0, $avail); $rightSpace = 0 }
                $line = if ($hint -and $rightSpace -gt ($hint.Length + 2)) {
                    $left + (' ' * ($rightSpace - $hint.Length)) + $hint
                } else { $left + (' ' * $rightSpace) }

                Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor Yellow
                if ($isActive) {
                    Write-Host -NoNewline $line -ForegroundColor Black -BackgroundColor Yellow
                } else {
                    Write-Host -NoNewline $line -ForegroundColor $color
                }
                Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
                $drawnLines++
                $rendered++
            }

            Write-Host ('  {0}{1}{2}' -f ([char]0x255A), $hLine, ([char]0x255D)) -ForegroundColor Yellow
            $drawnLines++
            $helpText = '  {0}/{1} Navigate  Space Toggle  Enter Confirm  Esc Cancel    {2} selected' -f ([char]0x2191), ([char]0x2193), $checked.Count
            Write-Host ($helpText + (' ' * [math]::Max(0, $w - $helpText.Length + 2))) -ForegroundColor Gray
            $drawnLines++

            $lastLineCount = $drawnLines

            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            switch ($k.VirtualKeyCode) {
                38 { $sel = if ($sel -gt 0) { $sel - 1 } else { $selectableIdx.Count - 1 } }
                40 { $sel = if ($sel -lt $selectableIdx.Count - 1) { $sel + 1 } else { 0 } }
                32 { if ($checked.ContainsKey($selectableIdx[$sel])) { $checked.Remove($selectableIdx[$sel]) } else { $checked[$selectableIdx[$sel]] = $true } }
                13 { return @($checked.Keys | Sort-Object | ForEach-Object { $Items[$_]['Key'] }) }
                27 { return @() }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Select-WinPulseFolderPath {
    [CmdletBinding()]
    param(
        [string]$Title = 'Select folder',
        [string]$StartPath = $null
    )

    $interactive = $true
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { $interactive = $false }

    if (-not $interactive) {
        Write-WinPulseHeader -title $Title
        $typedPath = Read-Host '  Type folder path'
        if ([string]::IsNullOrWhiteSpace($typedPath)) { return $null }
        return $typedPath
    }

    $currentPath = $null
    if (-not [string]::IsNullOrWhiteSpace($StartPath)) {
        $currentPath = $StartPath.Trim()
    }

    $w = Get-WinPulseBoxWidth
    $hLine = [string][char]0x2550 * ($w - 2)
    $vLine = [char]0x2551
    $sel = 0
    $viewTop = 0

    [Console]::CursorVisible = $false
    try {
        Clear-Host
        $startY = 0
        $lastLineCount = 0

        while ($true) {
            $items = @()
            $locationLabel = 'Drives'

            if ([string]::IsNullOrWhiteSpace($currentPath)) {
                $drives = @()
                $driveNote = $null
                try {
                    $drives = @(Get-PSDrive -PSProvider FileSystem | Sort-Object Name)
                }
                catch {
                    $driveNote = 'Could not list filesystem drives.'
                }

                foreach ($drive in @($drives)) {
                    $root = [string]$drive.Root
                    if ([string]::IsNullOrWhiteSpace($root)) {
                        $root = ('{0}:\' -f $drive.Name)
                    }
                    $items += @{ Label = $root; Type = 'Drive'; Path = $root }
                }

                if ($items.Count -eq 0) {
                    $note = if ($driveNote) { $driveNote } else { 'No filesystem drives found.' }
                    $items += @{ Label = $note; Separator = $true; Color = 'DarkYellow' }
                }
            }
            else {
                $locationLabel = $currentPath
                $items += @{ Label = '[Select this folder]'; Type = 'Select'; Path = $currentPath }

                $parentPath = $null
                try {
                    $currentItem = Get-Item -LiteralPath $currentPath -ErrorAction Stop
                    if ($currentItem -is [System.IO.DirectoryInfo] -and $currentItem.Parent) {
                        $parentPath = $currentItem.Parent.FullName
                    }
                }
                catch { }

                if ($parentPath) {
                    $items += @{ Label = '..  (go up)'; Type = 'Up'; Path = $parentPath }
                }
                else {
                    $items += @{ Label = '..  (go up)'; Type = 'DriveList'; Path = $null }
                }

                $listNote = $null
                try {
                    $dirs = @(Get-ChildItem -LiteralPath $currentPath -Directory -ErrorAction Stop | Sort-Object Name)
                    foreach ($dir in @($dirs)) {
                        $items += @{ Label = $dir.Name; Type = 'Directory'; Path = $dir.FullName }
                    }
                }
                catch {
                    $listNote = 'Could not list subfolders.'
                }

                if ($listNote) {
                    $items += @{ Label = $listNote; Separator = $true; Color = 'DarkYellow' }
                }
            }

            $selectableIdx = @()
            for ($i = 0; $i -lt $items.Count; $i++) {
                if (-not $items[$i]['Separator']) { $selectableIdx += $i }
            }
            if ($selectableIdx.Count -eq 0) {
                $sel = 0
            }
            elseif ($sel -ge $selectableIdx.Count) {
                $sel = $selectableIdx.Count - 1
            }

            try {
                $maxViewport = [math]::Max(1, [Console]::WindowHeight - 4)
            }
            catch {
                $maxViewport = 15
            }

            if ($selectableIdx.Count -gt 0) {
                $activeItemIdx = $selectableIdx[$sel]
                if ($activeItemIdx -lt $viewTop) { $viewTop = $activeItemIdx }
                if ($activeItemIdx -ge ($viewTop + $maxViewport)) { $viewTop = $activeItemIdx - $maxViewport + 1 }
            }
            if ($viewTop -ge $items.Count) { $viewTop = [math]::Max(0, $items.Count - 1) }

            if ($lastLineCount -gt 0) {
                [Console]::SetCursorPosition(0, $startY)
                $blankWidth = [math]::Min($w + 4, [Console]::BufferWidth - 1)
                if ($blankWidth -lt 1) { $blankWidth = 1 }
                $blank = ' ' * $blankWidth
                for ($c = 0; $c -lt $lastLineCount; $c++) { Write-Host $blank }
                [Console]::SetCursorPosition(0, $startY)
            }
            $drawnLines = 0

            $scrollInfo = if ($items.Count -gt $maxViewport -and $selectableIdx.Count -gt 0) { ' {0}/{1} ' -f ($sel + 1), $selectableIdx.Count } else { '' }
            $titleFull = ('{0} - {1}' -f $Title, $locationLabel)
            if ($scrollInfo) { $titleFull = '{0}  {1}' -f $titleFull, $scrollInfo }
            $titleMax = [math]::Max(8, $w - 8)
            if ($titleFull.Length -gt $titleMax) {
                $titleFull = $titleFull.Substring(0, $titleMax - 3) + '...'
            }

            Write-Host ('  {0}{1} {2} {3}{4}' -f ([char]0x2554), ([string][char]0x2550 * 2), $titleFull, ([string][char]0x2550 * [math]::Max(1, $w - $titleFull.Length - 6)), ([char]0x2557)) -ForegroundColor Yellow
            $drawnLines++

            $rendered = 0
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($rendered -ge $maxViewport) { break }
                if ($i -lt $viewTop) { continue }
                $item = $items[$i]

                if ($item['Separator']) {
                    $label = if ($item['Label']) { ' ' + $item['Label'] } else { '' }
                    $avail = $w - 2
                    if ($label.Length -gt $avail) { $label = $label.Substring(0, $avail) }
                    $line = $label + (' ' * [math]::Max(0, $avail - $label.Length))
                    $color = if ($item['Color']) { $item['Color'] } else { 'DarkGray' }
                    Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor Yellow
                    Write-Host -NoNewline $line -ForegroundColor $color
                    Write-Host ('{0}' -f $vLine) -ForegroundColor Yellow
                    $drawnLines++
                    $rendered++
                    continue
                }

                $isSelected = ($selectableIdx.Count -gt 0 -and $selectableIdx[$sel] -eq $i)
                $pointer = if ($isSelected) { '>' } else { ' ' }
                $left = ' {0} {1}' -f $pointer, $item['Label']
                $avail = $w - 4
                $rightSpace = $avail - $left.Length
                if ($rightSpace -lt 0) {
                    $left = $left.Substring(0, $avail)
                    $rightSpace = 0
                }
                $line = $left + (' ' * $rightSpace)

                Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor Yellow
                if ($isSelected) {
                    Write-Host -NoNewline $line -ForegroundColor Yellow
                }
                else {
                    Write-Host -NoNewline $line -ForegroundColor White
                }
                Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
                $drawnLines++
                $rendered++
            }

            Write-Host ('  {0}{1}{2}' -f ([char]0x255A), $hLine, ([char]0x255D)) -ForegroundColor Yellow
            $drawnLines++
            $helpText = '  {0}/{1} Navigate  Enter Select/Open  T Type path  Esc Cancel' -f ([char]0x2191), ([char]0x2193)
            Write-Host ($helpText + (' ' * [math]::Max(0, $w - $helpText.Length + 2))) -ForegroundColor Gray
            $drawnLines++

            $lastLineCount = $drawnLines

            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            switch ($k.VirtualKeyCode) {
                38 {
                    if ($selectableIdx.Count -gt 0) {
                        $sel = if ($sel -gt 0) { $sel - 1 } else { $selectableIdx.Count - 1 }
                    }
                }
                40 {
                    if ($selectableIdx.Count -gt 0) {
                        $sel = if ($sel -lt $selectableIdx.Count - 1) { $sel + 1 } else { 0 }
                    }
                }
                13 {
                    if ($selectableIdx.Count -gt 0) {
                        $selectedItem = $items[$selectableIdx[$sel]]
                        switch ($selectedItem['Type']) {
                            'Drive' { $currentPath = $selectedItem['Path']; $sel = 0; $viewTop = 0 }
                            'Directory' { $currentPath = $selectedItem['Path']; $sel = 0; $viewTop = 0 }
                            'Select' { return $selectedItem['Path'] }
                            'Up' { $currentPath = $selectedItem['Path']; $sel = 0; $viewTop = 0 }
                            'DriveList' { $currentPath = $null; $sel = 0; $viewTop = 0 }
                        }
                    }
                }
                27 { return $null }
                default {
                    $ch = [string]$k.Character
                    if ($ch) {
                        $ch = $ch.ToUpperInvariant()
                        if ($ch -eq 'T' -or $ch -eq 'M') {
                            [Console]::CursorVisible = $true
                            Write-Host ''
                            $typedPath = Read-Host '  Type folder path'
                            [Console]::CursorVisible = $false
                            if (-not [string]::IsNullOrWhiteSpace($typedPath)) {
                                return $typedPath
                            }
                            Clear-Host
                            $lastLineCount = 0
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Write-WinPulseDashboardLine {
    [CmdletBinding()]
    param(
        [string]$Label,
        [string]$Value,
        [string]$State = 'Info',
        [int]$BoxWidth = 88
    )

    $badge = switch ($State) {
        'OK'       { @{ Text = ' OK '; Color = 'Green' } }
        'Warning'  { @{ Text = 'WARN'; Color = 'Yellow' } }
        'Critical' { @{ Text = 'CRIT'; Color = 'Red' } }
        default    { @{ Text = 'INFO'; Color = 'DarkCyan' } }
    }
    $vLine = [char]0x2551

    $inner = $BoxWidth - 3
    $content = ' [{0}] {1,-10} {2}' -f $badge.Text, $Label, $Value
    if ($content.Length -gt $inner) { $content = $content.Substring(0, $inner) }
    $content = $content.PadRight($inner)

    Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor Yellow
    Write-Host -NoNewline ' ' -ForegroundColor Yellow
    Write-Host -NoNewline ('[{0}]' -f $badge.Text) -ForegroundColor $badge.Color
    $rest = $content.Substring($badge.Text.Length + 3)
    Write-Host -NoNewline $rest -ForegroundColor Gray
    Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
}

function Write-WinPulseDashboardSegLine {
    # Like Write-WinPulseDashboardLine but Value is an array of @{Text;Color} segments.
    param([string]$Label, [string]$State = 'Info', [array]$Segments, [int]$BoxWidth = 88)
    $badge = switch ($State) {
        'OK'       { @{ Text = ' OK '; Color = 'Green' } }
        'Warning'  { @{ Text = 'WARN'; Color = 'Yellow' } }
        'Critical' { @{ Text = 'CRIT'; Color = 'Red' } }
        default    { @{ Text = 'INFO'; Color = 'Gray' } }
    }
    $vLine   = [char]0x2551
    $inner   = $BoxWidth - 3
    # Fixed chars before segments: ' ' + '[STAT]'(6) + ' Label     '(12) = 19; segArea = inner - 19
    $segArea = $inner - $badge.Text.Length - 3 - 12
    $totalLen = 0
    foreach ($s in $Segments) { $totalLen += ([string]$s['Text']).Length }
    $pad = [math]::Max(0, $segArea - $totalLen)
    Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor Yellow
    Write-Host -NoNewline ' ' -ForegroundColor Yellow
    Write-Host -NoNewline ('[{0}]' -f $badge.Text) -ForegroundColor $badge.Color
    Write-Host -NoNewline (' {0,-10} ' -f $Label) -ForegroundColor Gray
    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $t = [string]$Segments[$i]['Text']
        if ($i -eq $Segments.Count - 1) { $t = $t + (' ' * $pad) }
        Write-Host -NoNewline $t -ForegroundColor ([string]$Segments[$i]['Color'])
    }
    Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
}

function Show-WinPulseDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    try { $Host.UI.RawUI.BackgroundColor = 'Black' } catch {}
    Clear-Host
    # After returning from a submenu the console buffer may be scrolled, so
    # Clear-Host can leave the viewport (and cursor) deep in the buffer. Force
    # both back to the top-left so the dashboard draws at row 0 and the menu
    # below it fits, instead of overflowing and tripping the menu's clear-screen
    # safeguard (which would wipe the dashboard - it would just flash and vanish).
    try {
        $rawUi = $Host.UI.RawUI
        $topLeft = New-Object System.Management.Automation.Host.Coordinates 0, 0
        $rawUi.WindowPosition = $topLeft
        $rawUi.CursorPosition = $topLeft
    }
    catch { }

    $w = Get-WinPulseBoxWidth
    $hLine = [string][char]0x2550 * ($w - 2)
    $vLine = [char]0x2551

    # Top header (includes the build version for support/screenshots)
    $titleBar = ' WinPulse {0} ' -f $script:WinPulseVersion
    $titleFill = [math]::Max(1, $w - 4 - $titleBar.Length)
    Write-Host ('  {0}{1}{2}{3}{4}' -f ([char]0x2554), ([string][char]0x2550 * 2), $titleBar, ([string][char]0x2550 * $titleFill), ([char]0x2557)) -ForegroundColor Yellow

    # System line
    $sysLine = ' {0} | {1} | up {2}' -f $scan.System.Hostname, $scan.System.WindowsVersion, $scan.System.Uptime
    if ($sysLine.Length -gt ($w - 4)) { $sysLine = $sysLine.Substring(0, $w - 4) }
    Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor Yellow
    Write-Host -NoNewline ($sysLine.PadRight($w - 4)) -ForegroundColor White
    Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow

    # Separator
    Write-Host ('  {0}{1}{2}' -f ([char]0x2560), $hLine, ([char]0x2563)) -ForegroundColor Yellow

    # Hardware
    # Hardware row
    $ramState   = Get-WinPulseStateFromPercent -percent $scan.Hardware.Ram.UsedPercent
    $cDisk      = $scan.Hardware.Disks | Where-Object { $_.Drive -eq 'C:' } | Select-Object -First 1
    $cDiskState = if ($cDisk) { Get-WinPulseStateFromPercent -percent $cDisk.UsedPercent } else { 'OK' }
    $hwState    = if ($cDiskState -eq 'Critical' -or $ramState -eq 'Critical') { 'Critical' } elseif ($cDiskState -eq 'Warning' -or $ramState -eq 'Warning') { 'Warning' } else { 'OK' }
    $ramColor   = switch ($ramState)   { 'Critical' { 'Red' } 'Warning' { 'Yellow' } default { 'Gray' } }
    $diskColor  = switch ($cDiskState) { 'Critical' { 'Red' } 'Warning' { 'Yellow' } default { 'Gray' } }
    $smartColor = if ($scan.Hardware.SmartHealthy) { 'Gray' } else { 'Red' }
    $smartLabel = if ($scan.Hardware.SmartHealthy) { 'SMART OK' } else { 'SMART FAIL' }
    $cDiskText  = if ($cDisk) { 'C: {0}% {1}' -f $cDisk.UsedPercent, $cDisk.Free } else { 'C: N/A' }
    $hwSegs = [System.Collections.Generic.List[hashtable]]::new()
    $hwSegs.Add(@{ Text = 'RAM {0}%' -f $scan.Hardware.Ram.UsedPercent; Color = $ramColor })
    $hwSegs.Add(@{ Text = ' | '; Color = 'Gray' })
    $hwSegs.Add(@{ Text = $cDiskText; Color = $diskColor })
    $hwSegs.Add(@{ Text = ' | '; Color = 'Gray' })
    $hwSegs.Add(@{ Text = $smartLabel; Color = $smartColor })
    if ($scan.Temperatures -and $scan.Temperatures.CPUTempCelsius) {
        $tempC     = [int]$scan.Temperatures.CPUTempCelsius
        $tempColor = if ($tempC -gt 85) { 'Red' } elseif ($tempC -gt 70) { 'Yellow' } else { 'Gray' }
        $hwSegs.Add(@{ Text = ' | CPU {0}C' -f $tempC; Color = $tempColor })
    }
    if ($null -ne $scan.Hardware.CpuLoadPercent) {
        $cpuLColor = if ($scan.Hardware.CpuLoadPercent -ge 80) { 'Red' } elseif ($scan.Hardware.CpuLoadPercent -ge 60) { 'Yellow' } else { 'Gray' }
        $hwSegs.Add(@{ Text = (' | CPU {0}%' -f $scan.Hardware.CpuLoadPercent); Color = $cpuLColor })
    }
    Write-WinPulseDashboardSegLine -Label 'Hardware' -State $hwState -Segments $hwSegs.ToArray()

    # Security row
    $avNames = @()
    if ($scan.Security.Antivirus -and $scan.Security.Antivirus.Products) {
        $avNames = @($scan.Security.Antivirus.Products | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    # Remove Windows Defender short label when a third-party AV is also present
    if ($avNames.Count -gt 1) {
        $avNames = @($avNames | Where-Object { $_ -notmatch '^Win$|^Windows Defender$|^WinDefender$' })
    }
    $avLabel   = if ($avNames.Count -gt 0) { ($avNames -join ', ') } else { 'None' }
    if ($avLabel.Length -gt 20) { $avLabel = $avLabel.Substring(0, 20) }
    $fwLabel   = if ($scan.Security.FirewallEnabled) { 'Firewall ON' } else { 'Firewall OFF' }
    $fwColor   = if ($scan.Security.FirewallEnabled) { 'Gray' } else { 'Red' }
    $bitLockerOn = $false
    if ($scan.Security.BitLocker -and $scan.Security.BitLocker.Count -gt 0) {
        $bitLockerOn = @($scan.Security.BitLocker | Where-Object { ([string]$_.ProtectionStatus) -match 'On|1' }).Count -gt 0
    }
    $blLabel   = if ($bitLockerOn) { 'BitLocker ON' } else { 'BitLocker OFF' }
    $blColor   = if ($bitLockerOn) { 'Cyan' } else { 'Gray' }
    $secState  = if ($scan.Security.Antivirus.EffectiveRealtimeProtection -and $scan.Security.FirewallEnabled) { 'OK' } else { 'Critical' }
    $secSegs   = @(
        @{ Text = 'AV {0}' -f $avLabel; Color = 'Gray' }
        @{ Text = ' | '; Color = 'Gray' }
        @{ Text = $fwLabel; Color = $fwColor }
        @{ Text = ' | '; Color = 'Gray' }
        @{ Text = $blLabel; Color = $blColor }
    )
    Write-WinPulseDashboardSegLine -Label 'Security' -State $secState -Segments $secSegs

    # Network
    $netState = if ($scan.Network.Internet) { 'OK' } else { 'Warning' }
    $netSegs = [System.Collections.Generic.List[hashtable]]::new()
    $netSegs.Add(@{ Text = [string]$scan.Network.IPv4; Color = 'Gray' })
    $netSegs.Add(@{ Text = (' | GW {0}' -f $scan.Network.Gateway); Color = 'Gray' })
    $netSegs.Add(@{ Text = (' | Net {0}' -f $(if ($scan.Network.Internet) { 'OK' } else { 'FAIL' })); Color = $(if ($scan.Network.Internet) { 'Gray' } else { 'Red' }) })
    if ($scan.NetworkDetail -and $scan.NetworkDetail.WiFi -and $scan.NetworkDetail.WiFi.SSID) {
        $ssid = [string]$scan.NetworkDetail.WiFi.SSID
        if ($ssid.Length -gt 15) { $ssid = $ssid.Substring(0, 15) }
        $sig = $scan.NetworkDetail.WiFi.SignalPercent
        $wifiText = if ($sig) { ' | WiFi: {0} {1}%' -f $ssid, $sig } else { ' | WiFi: {0}' -f $ssid }
        $wifiColor = if ($sig -and $sig -lt 40) { 'Red' } elseif ($sig -and $sig -lt 70) { 'Yellow' } else { 'Gray' }
        $baseLen = ($netSegs | ForEach-Object { ([string]$_['Text']).Length } | Measure-Object -Sum).Sum
        if (($baseLen + $wifiText.Length) -le 62) {
            $netSegs.Add(@{ Text = $wifiText; Color = $wifiColor })
        }
    }
    Write-WinPulseDashboardSegLine -Label 'Network' -State $netState -Segments $netSegs.ToArray()

    # Health row
    $healthState  = if ($scan.Health.CriticalLast24Hours -eq 0 -and -not $scan.Health.PendingReboot -and $scan.Health.BsodRecentCount -eq 0) { 'OK' } elseif ($scan.Health.BsodRecentCount -gt 0 -or $scan.Health.CriticalLast24Hours -gt 0) { 'Critical' } else { 'Warning' }
    $bsodColor    = if ($scan.Health.BsodRecentCount -gt 0) { 'Red' } else { 'Gray' }
    $critColor    = if ($scan.Health.CriticalLast24Hours -gt 0) { 'Red' } else { 'Gray' }
    $rebootText   = if ($scan.Health.PendingReboot) { 'Reboot YES' } else { 'Reboot No' }
    $rebootColor  = if ($scan.Health.PendingReboot) { 'Yellow' } else { 'Gray' }
    $healthSegs   = @(
        @{ Text = 'BSOD {0}' -f $scan.Health.BsodRecentCount; Color = $bsodColor }
        @{ Text = ' | '; Color = 'Gray' }
        @{ Text = 'Events(24h) {0}' -f $scan.Health.CriticalLast24Hours; Color = $critColor }
        @{ Text = ' | '; Color = 'Gray' }
        @{ Text = $rebootText; Color = $rebootColor }
    )
    Write-WinPulseDashboardSegLine -Label 'Health' -State $healthState -Segments $healthSegs

    # License
    if ($scan.License) {
        $licState = if ($scan.License.ActivationStatus -eq 'Activated') { 'OK' } else { 'Warning' }
        Write-WinPulseDashboardLine -Label 'License' -Value ('{0} | {1} | ...{2}' -f $scan.License.ActivationStatus, $scan.License.LicenseType, $scan.License.PartialProductKey) -State $licState
    }

    # Drivers
    if ($scan.Drivers) {
        $probCount = $scan.Drivers.Problematic.Count
        $unsignedCount = $scan.Drivers.Unsigned.Count
        $drvState = if ($probCount -gt 0) { 'Warning' } elseif ($unsignedCount -gt 5) { 'Warning' } else { 'OK' }
        Write-WinPulseDashboardLine -Label 'Drivers' -Value ('Problems {0} | Unsigned {1} | Recent {2}' -f $probCount, $unsignedCount, $scan.Drivers.RecentlyChanged.Count) -State $drvState
    }

    if ($scan.HardwareDetail -and $scan.HardwareDetail.Battery.Present) {
        $bat = $scan.HardwareDetail.Battery
        $batState = if (-not $bat.HealthPercent) { 'OK' } elseif ($bat.HealthPercent -lt 60) { 'Critical' } elseif ($bat.HealthPercent -lt 80) { 'Warning' } else { 'OK' }
        $batHColor = switch ($batState) { 'Critical' { 'Red' } 'Warning' { 'Yellow' } default { 'Gray' } }
        $batSegs = [System.Collections.Generic.List[hashtable]]::new()
        if ($bat.HealthPercent) {
            $batSegs.Add(@{ Text = ('Health {0}%' -f $bat.HealthPercent); Color = $batHColor })
        }
        if ($bat.DesignCapacityWh -and $bat.FullChargeCapacityWh) {
            $batSegs.Add(@{ Text = ' | '; Color = 'Gray' })
            $batSegs.Add(@{ Text = ('{0} / {1} Wh' -f $bat.FullChargeCapacityWh, $bat.DesignCapacityWh); Color = 'Gray' })
        }
        if ($bat.CycleCount) {
            $batSegs.Add(@{ Text = (' | Cycles {0}' -f $bat.CycleCount); Color = 'Gray' })
        }
        if ($batSegs.Count -eq 0) {
            $batSegs.Add(@{ Text = 'Present (wear data unavailable)'; Color = 'Gray' })
        }
        Write-WinPulseDashboardSegLine -Label 'Battery' -State $batState -Segments $batSegs.ToArray()
    }

    # Findings separator
    Write-Host ('  {0}{1}{2}' -f ([char]0x2560), $hLine, ([char]0x2563)) -ForegroundColor Yellow

    $findings = @(Get-WinPulseTriageFindings -scan $scan)
    if ($findings.Count -eq 0) {
        $fLine = ' No issues detected'
        Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor Yellow
        Write-Host -NoNewline (' {0}' -f $fLine.PadRight($w - 4)) -ForegroundColor Green
        Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
    }
    else {
        $ordered = @($findings | Sort-Object @{ Expression = { if ($_.Severity -eq 'Critical') { 0 } else { 1 } } })
        foreach ($f in $ordered) {
            $fColor = if ($f.Severity -eq 'Critical') { 'Red' } else { 'Yellow' }
            $fBadge = if ($f.Severity -eq 'Critical') { '[CRIT]' } else { '[WARN]' }
            $fText = ' {0} {1}' -f $fBadge, $f.Message
            if ($fText.Length -gt ($w - 4)) { $fText = $fText.Substring(0, $w - 7) + '...' }
            Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor Yellow
            Write-Host -NoNewline ($fText.PadRight($w - 4)) -ForegroundColor $fColor
            Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow
        }
    }

    # Scanned timestamp - inside box, last line before bottom border
    $scanText = ' Scanned: {0}' -f $scan.GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor Yellow
    Write-Host -NoNewline ($scanText.PadRight($w - 4)) -ForegroundColor Gray
    Write-Host (' {0}' -f $vLine) -ForegroundColor Yellow

    # Bottom border
    Write-Host ('  {0}{1}{2}' -f ([char]0x255A), $hLine, ([char]0x255D)) -ForegroundColor Yellow
}

function Get-WinPulseTriageFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    $findings = @()

    if ($scan.Health.PendingReboot) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = 'Pending reboot detected (updates/components waiting).' }
    }
    if ($scan.System.Firmware -eq 'UEFI' -and $scan.Security.SecureBootState -eq 'Off') {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = 'UEFI boot with Secure Boot disabled.' }
    }
    if (-not $scan.Security.FirewallEnabled) {
        $findings += [pscustomobject]@{ Severity = 'Critical'; Message = 'Windows Firewall is OFF.' }
    }
    if (-not $scan.Security.Antivirus.EffectiveRealtimeProtection) {
        $findings += [pscustomobject]@{ Severity = 'Critical'; Message = 'No effective real-time AV protection detected.' }
    }
    if (-not $scan.Network.Internet) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = 'Internet connectivity check failed.' }
    }
    if ($scan.Health.CriticalLast24Hours -gt 0) {
        $findings += [pscustomobject]@{ Severity = 'Critical'; Message = ('Critical system events (24h): {0}' -f $scan.Health.CriticalLast24Hours) }
    }
    if ($scan.Health.BsodRecentCount -gt 0) {
        $findings += [pscustomobject]@{ Severity = 'Critical'; Message = ('BSOD events (7d): {0}' -f $scan.Health.BsodRecentCount) }
    }
    if ($scan.Hardware.Disks | Where-Object { $_.Drive -eq 'C:' -and $_.UsedPercent -ge 90 }) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = 'System drive C: usage is above 90%.' }
    }


    # Extended triage findings
    if ($scan.TPM -and -not $scan.TPM.Present) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = 'TPM not detected (Win 11 incompatible).' }
    }
    elseif ($scan.TPM -and $scan.TPM.Present -and -not $scan.TPM.Win11Compatible) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('TPM version {0} detected (Win 11 requires 2.0).' -f $scan.TPM.Version) }
    }
    if ($scan.Drivers -and $scan.Drivers.Problematic.Count -gt 0) {
        $sev = if ($scan.Drivers.Problematic.Count -gt 3) { 'Critical' } else { 'Warning' }
        $findings += [pscustomobject]@{ Severity = $sev; Message = ('Problematic device drivers: {0}' -f $scan.Drivers.Problematic.Count) }
    }
    if ($scan.Startup -and $scan.Startup.FailedAutoServices.Count -gt 3) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('Failed auto-start services: {0}' -f $scan.Startup.FailedAutoServices.Count) }
    }
    if ($scan.License -and $scan.License.ActivationStatus -ne 'Activated') {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('Windows license: {0}' -f $scan.License.ActivationStatus) }
    }
    if ($scan.HardwareDetail -and $scan.HardwareDetail.Battery.Present -and $scan.HardwareDetail.Battery.HealthPercent) {
        if ($scan.HardwareDetail.Battery.HealthPercent -lt 30) {
            $findings += [pscustomobject]@{ Severity = 'Critical'; Message = ('Battery critically degraded: {0}%' -f $scan.HardwareDetail.Battery.HealthPercent) }
        }
        elseif ($scan.HardwareDetail.Battery.HealthPercent -lt 50) {
            $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('Battery health is low: {0}%' -f $scan.HardwareDetail.Battery.HealthPercent) }
        }
    }
    if ($scan.Temperatures -and $scan.Temperatures.CPUTempCelsius) {
        if ($scan.Temperatures.CPUTempCelsius -gt 85) {
            $findings += [pscustomobject]@{ Severity = 'Critical'; Message = ('CPU temperature critical: {0} C' -f $scan.Temperatures.CPUTempCelsius) }
        }
        elseif ($scan.Temperatures.CPUTempCelsius -gt 70) {
            $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('CPU temperature elevated: {0} C' -f $scan.Temperatures.CPUTempCelsius) }
        }
    }
    if ($scan.Printers -and $scan.Printers.StuckJobs.Count -gt 0) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('Print jobs stuck in queue: {0}' -f $scan.Printers.StuckJobs.Count) }
    }

    return @($findings)
}

function Show-WinPulseTriageSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    $findings = @(Get-WinPulseTriageFindings -scan $scan)
    $overall = 'OK'
    $overallColor = 'Green'
    if ($findings | Where-Object { $_.Severity -eq 'Critical' }) {
        $overall = 'CRIT'
        $overallColor = 'Red'
    }
    elseif ($findings.Count -gt 0) {
        $overall = 'WARN'
        $overallColor = 'Yellow'
    }

    Write-WinPulseHeader -title 'Fast Triage'
    Write-Host ('Overall: {0}' -f $overall) -ForegroundColor $overallColor

    if ($findings.Count -eq 0) {
        Write-Host 'Top findings: none' -ForegroundColor Green
        return
    }

    $ordered = @(
        $findings | Sort-Object @{ Expression = {
                if ($_.Severity -eq 'Critical') { 0 } elseif ($_.Severity -eq 'Warning') { 1 } else { 2 }
            } }, Message
    )
    $top = @($ordered | Select-Object -First 3)
    Write-Host 'Top findings:' -ForegroundColor Yellow
    foreach ($item in $top) {
        $color = if ($item.Severity -eq 'Critical') { 'Red' } elseif ($item.Severity -eq 'Warning') { 'Yellow' } else { 'White' }
        Write-Host ('- [{0}] {1}' -f $item.Severity.ToUpperInvariant(), $item.Message) -ForegroundColor $color
    }
}

# -- HTML Report --------------------------------------------------------------

function ConvertTo-WinPulseHtmlTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Data,
        [string[]]$Columns
    )

    if ($Data.Count -eq 0) { return '<p class="empty">No data available.</p>' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')

    $keys = if ($Columns) { $Columns } else { $Data[0].Keys }
    foreach ($key in $keys) {
        [void]$sb.Append('<th>{0}</th>' -f [System.Web.HttpUtility]::HtmlEncode($key))
    }
    [void]$sb.Append('</tr></thead><tbody>')

    foreach ($row in $Data) {
        [void]$sb.Append('<tr>')
        foreach ($key in $keys) {
            $val = if ($row -is [hashtable] -or $row -is [System.Collections.Specialized.OrderedDictionary]) { $row[$key] } else { $row.$key }
            [void]$sb.Append('<td>{0}</td>' -f [System.Web.HttpUtility]::HtmlEncode([string]$val))
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-WinPulseHtmlStateClass {
    [CmdletBinding()]
    param([string]$state)
    switch ($state) {
        'OK' { 'state-ok' }
        'Warning' { 'state-warn' }
        'Critical' { 'state-crit' }
        default { 'state-info' }
    }
}

function Export-WinPulseHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    # The full HTML report includes the detail-only sections, which are deferred
    # at startup. Make sure they are loaded before rendering.
    $scan = Complete-WinPulseDetailScan -scan $scan

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $e = [System.Web.HttpUtility]

    $findings = @(Get-WinPulseTriageFindings -scan $scan)
    $overall = 'OK'
    if ($findings | Where-Object { $_.Severity -eq 'Critical' }) { $overall = 'CRITICAL' }
    elseif ($findings.Count -gt 0) { $overall = 'WARNING' }
    $overallClass = switch ($overall) { 'CRITICAL' { 'state-crit' }; 'WARNING' { 'state-warn' }; default { 'state-ok' } }

    $sb = [System.Text.StringBuilder]::new()

    # -- HTML Head ------------------------------------------------------------
    [void]$sb.Append(@'
<!DOCTYPE html>
<html lang="cs">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WinPulse Report</title>
<style>
:root{--bg:#1a1a2e;--card:#16213e;--border:#0f3460;--text:#e0e0e0;--ok:#2ecc71;--warn:#f39c12;--crit:#e74c3c;--info:#3498db;--muted:#7f8c8d}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,Geneva,sans-serif;background:var(--bg);color:var(--text);line-height:1.5;padding:20px}
.container{max-width:1100px;margin:0 auto}
header{text-align:center;padding:20px 0;border-bottom:2px solid var(--border);margin-bottom:20px}
header h1{font-size:1.8em;color:var(--info)}
header .subtitle{color:var(--muted);font-size:0.9em}
.overall-badge{display:inline-block;padding:6px 20px;border-radius:4px;font-weight:bold;font-size:1.1em;margin:10px 0}
.state-ok{color:var(--ok);border:1px solid var(--ok)}
.state-warn{color:var(--warn);border:1px solid var(--warn)}
.state-crit{color:var(--crit);border:1px solid var(--crit)}
.state-info{color:var(--info);border:1px solid var(--info)}
.bg-ok{background:rgba(46,204,113,0.1)} .bg-warn{background:rgba(243,156,18,0.1)} .bg-crit{background:rgba(231,76,60,0.1)}
section{background:var(--card);border:1px solid var(--border);border-radius:6px;padding:16px;margin-bottom:16px}
section h2{color:var(--info);font-size:1.15em;margin-bottom:10px;border-bottom:1px solid var(--border);padding-bottom:6px}
table{width:100%;border-collapse:collapse;font-size:0.88em}
th{background:var(--border);color:var(--text);text-align:left;padding:6px 10px;white-space:nowrap}
td{padding:5px 10px;border-bottom:1px solid rgba(255,255,255,0.05)}
tr:hover td{background:rgba(255,255,255,0.03)}
.kv{display:grid;grid-template-columns:200px 1fr;gap:4px 16px;font-size:0.92em}
.kv .k{color:var(--muted);font-weight:600} .kv .v{color:var(--text)}
.findings-list{list-style:none;padding:0}
.findings-list li{padding:4px 8px;margin:2px 0;border-radius:3px;font-size:0.92em}
.empty{color:var(--muted);font-style:italic;font-size:0.9em}
.notes-area{width:100%;min-height:80px;background:var(--bg);border:1px solid var(--border);color:var(--text);padding:8px;border-radius:4px;font-family:inherit;resize:vertical}
details summary{cursor:pointer;color:var(--info);font-weight:600;padding:4px 0}
footer{text-align:center;color:var(--muted);font-size:0.8em;padding:20px 0;border-top:1px solid var(--border);margin-top:20px}
@media print{
  body{background:#fff;color:#000;padding:10px}
  .container{max-width:100%}
  section{border:1px solid #ccc;break-inside:avoid}
  :root{--bg:#fff;--card:#fff;--border:#ccc;--text:#000;--muted:#666}
  th{background:#eee;color:#000}
  td{border-bottom:1px solid #ddd}
  .notes-area{border:1px solid #ccc;background:#fafafa;color:#000}
  .state-ok{color:#16a34a} .state-warn{color:#ca8a04} .state-crit{color:#dc2626} .state-info{color:#2563eb}
  .bg-ok{background:#f0fdf4} .bg-warn{background:#fefce8} .bg-crit{background:#fef2f2}
}
</style>
</head>
<body>
<div class="container">
'@)

    # -- Header ---------------------------------------------------------------
    [void]$sb.Append(('<header><h1>WinPulse Diagnostic Report</h1><p class="subtitle">{0} | Generated: {1}</p>' -f $e::HtmlEncode($scan.System.Hostname), $scan.GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$sb.Append(('<div class="overall-badge {0}">Overall: {1}</div>' -f $overallClass, $overall))
    [void]$sb.Append('</header>')

    # -- Triage ---------------------------------------------------------------
    [void]$sb.Append('<section><h2>Triage Findings</h2>')
    if ($findings.Count -eq 0) {
        [void]$sb.Append('<p class="state-ok">No issues detected.</p>')
    }
    else {
        [void]$sb.Append('<ul class="findings-list">')
        foreach ($f in ($findings | Sort-Object @{ Expression = { if ($_.Severity -eq 'Critical') { 0 } else { 1 } } })) {
            $cls = if ($f.Severity -eq 'Critical') { 'bg-crit state-crit' } else { 'bg-warn state-warn' }
            [void]$sb.Append(('<li class="{0}">[{1}] {2}</li>' -f $cls, $e::HtmlEncode($f.Severity.ToUpperInvariant()), $e::HtmlEncode($f.Message)))
        }
        [void]$sb.Append('</ul>')
    }
    [void]$sb.Append('</section>')

    # -- Technician Notes -----------------------------------------------------
    [void]$sb.Append('<section><h2>Technician Notes</h2><textarea class="notes-area" placeholder="Add notes here before printing..."></textarea></section>')

    # -- System Info ----------------------------------------------------------
    [void]$sb.Append('<section><h2>System Information</h2><div class="kv">')
    $sysFields = [ordered]@{
        'Hostname' = $scan.System.Hostname; 'Model' = $scan.System.Model; 'Serial' = $scan.System.Serial
        'Windows' = $scan.System.WindowsVersion; 'Uptime' = $scan.System.Uptime
        'Domain' = ('{0} ({1})' -f $scan.System.Domain, $(if ($scan.System.DomainJoined) { 'Joined' } else { 'Workgroup' }))
        'Firmware' = $scan.System.Firmware; 'SecureBoot' = $scan.Security.SecureBootState
    }
    foreach ($kv in $sysFields.GetEnumerator()) {
        [void]$sb.Append(('<span class="k">{0}</span><span class="v">{1}</span>' -f $e::HtmlEncode($kv.Key), $e::HtmlEncode([string]$kv.Value)))
    }
    [void]$sb.Append('</div></section>')

    # -- Hardware Details -----------------------------------------------------
    if ($scan.HardwareDetail) {
        [void]$sb.Append('<section><h2>Hardware Details</h2>')

        [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">CPU</h3><div class="kv">')
        $c = $scan.HardwareDetail.CPU
        foreach ($kv in ([ordered]@{ 'Model' = $c.Model; 'Cores / Threads' = ('{0} / {1}' -f $c.Cores, $c.Threads); 'Base Freq' = ('{0} MHz' -f $c.BaseFreqMHz); 'Architecture' = $c.Architecture }).GetEnumerator()) {
            [void]$sb.Append(('<span class="k">{0}</span><span class="v">{1}</span>' -f $e::HtmlEncode($kv.Key), $e::HtmlEncode([string]$kv.Value)))
        }
        [void]$sb.Append('</div>')

        if ($scan.HardwareDetail.GPU.Count -gt 0) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">GPU</h3>')
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.HardwareDetail.GPU -Columns @('Name','DriverVersion','VRAM','Resolution')))
        }

        if ($scan.HardwareDetail.DIMMs.Count -gt 0) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">Memory Modules</h3>')
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.HardwareDetail.DIMMs -Columns @('Slot','Capacity','SpeedMHz','Type','Manufacturer')))
        }

        [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">Motherboard</h3><div class="kv">')
        $mb = $scan.HardwareDetail.Motherboard
        foreach ($kv in ([ordered]@{ 'Manufacturer' = $mb.Manufacturer; 'Model' = $mb.Model; 'BIOS' = ('{0} ({1})' -f $mb.BIOSVersion, $mb.BIOSDate) }).GetEnumerator()) {
            [void]$sb.Append(('<span class="k">{0}</span><span class="v">{1}</span>' -f $e::HtmlEncode($kv.Key), $e::HtmlEncode([string]$kv.Value)))
        }
        [void]$sb.Append('</div>')

        if ($scan.HardwareDetail.Battery.Present) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">Battery</h3><div class="kv">')
            $bat = $scan.HardwareDetail.Battery
            $batHealth = if ($bat.HealthPercent) { '{0}%' -f $bat.HealthPercent } else { 'N/A' }
            $batClass = if ($bat.HealthPercent -and $bat.HealthPercent -lt 50) { 'state-crit' } elseif ($bat.HealthPercent -and $bat.HealthPercent -lt 80) { 'state-warn' } else { 'state-ok' }
            [void]$sb.Append(('<span class="k">Health</span><span class="v {0}">{1}</span>' -f $batClass, $e::HtmlEncode($batHealth)))
            [void]$sb.Append(('<span class="k">Cycle Count</span><span class="v">{0}</span>' -f $(if ($bat.CycleCount) { $bat.CycleCount } else { 'N/A' })))
            [void]$sb.Append(('<span class="k">Design / Full Charge</span><span class="v">{0} Wh / {1} Wh</span>' -f $bat.DesignCapacityWh, $bat.FullChargeCapacityWh))
            [void]$sb.Append('</div>')
        }
        [void]$sb.Append('</section>')
    }

    # -- RAM & Disk -----------------------------------------------------------
    [void]$sb.Append('<section><h2>Storage &amp; Memory</h2><div class="kv">')
    $ram = $scan.Hardware.Ram
    [void]$sb.Append(('<span class="k">RAM</span><span class="v">{0} used ({1}%) | {2} free | {3} total</span>' -f $ram.Used, $ram.UsedPercent, $ram.Free, $ram.Total))
    [void]$sb.Append(('<span class="k">SMART</span><span class="v {0}">{1}</span>' -f $(if ($scan.Hardware.SmartHealthy) { 'state-ok' } else { 'state-crit' }), $(if ($scan.Hardware.SmartHealthy) { 'Healthy' } else { 'FAILURE PREDICTED' })))
    [void]$sb.Append('</div>')
    if ($scan.Hardware.Disks.Count -gt 0) {
        $diskData = @($scan.Hardware.Disks | ForEach-Object { [ordered]@{ Drive = $_.Drive; Size = $_.Size; Free = $_.Free; 'Used%' = $_.UsedPercent } })
        [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $diskData))
    }
    [void]$sb.Append('</section>')

    # -- Temperatures ---------------------------------------------------------
    if ($scan.Temperatures) {
        [void]$sb.Append('<section><h2>Temperatures</h2><div class="kv">')
        $cpuT = if ($scan.Temperatures.CPUTempCelsius) { '{0} C' -f $scan.Temperatures.CPUTempCelsius } else { 'N/A' }
        $cpuTClass = if ($scan.Temperatures.CPUTempCelsius -and $scan.Temperatures.CPUTempCelsius -gt 85) { 'state-crit' } elseif ($scan.Temperatures.CPUTempCelsius -and $scan.Temperatures.CPUTempCelsius -gt 70) { 'state-warn' } else { 'state-ok' }
        [void]$sb.Append(('<span class="k">CPU Temperature</span><span class="v {0}">{1}</span>' -f $cpuTClass, $e::HtmlEncode($cpuT)))
        [void]$sb.Append(('<span class="k">Source</span><span class="v">{0}</span>' -f $e::HtmlEncode($scan.Temperatures.CPUTempSource)))
        [void]$sb.Append('</div>')
        if ($scan.Temperatures.DiskTemps.Count -gt 0) {
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Temperatures.DiskTemps))
        }
        [void]$sb.Append(('<p class="empty">{0}</p>' -f $e::HtmlEncode($scan.Temperatures.Note)))
        [void]$sb.Append('</section>')
    }

    # -- TPM ------------------------------------------------------------------
    if ($scan.TPM) {
        [void]$sb.Append('<section><h2>TPM Status</h2><div class="kv">')
        $t = $scan.TPM
        $tpmClass = if ($t.Win11Compatible) { 'state-ok' } elseif ($t.Present) { 'state-warn' } else { 'state-crit' }
        [void]$sb.Append(('<span class="k">Present</span><span class="v">{0}</span>' -f $t.Present))
        [void]$sb.Append(('<span class="k">Enabled</span><span class="v">{0}</span>' -f $t.Enabled))
        [void]$sb.Append(('<span class="k">Version</span><span class="v {0}">{1}</span>' -f $tpmClass, $e::HtmlEncode($t.Version)))
        [void]$sb.Append(('<span class="k">Manufacturer</span><span class="v">{0}</span>' -f $e::HtmlEncode($t.Manufacturer)))
        [void]$sb.Append(('<span class="k">Win 11 Compatible</span><span class="v {0}">{1}</span>' -f $tpmClass, $t.Win11Compatible))
        [void]$sb.Append('</div></section>')
    }

    # -- Security -------------------------------------------------------------
    [void]$sb.Append('<section><h2>Security</h2><div class="kv">')
    $avLabel = if ($scan.Security.Antivirus.Products.Count -gt 0) { ($scan.Security.Antivirus.Products | ForEach-Object { $_.Name } | Where-Object { $_ } | Sort-Object -Unique) -join ', ' } else { 'None detected' }
    [void]$sb.Append(('<span class="k">Antivirus</span><span class="v">{0}</span>' -f $e::HtmlEncode($avLabel)))
    [void]$sb.Append(('<span class="k">Real-time Protection</span><span class="v {0}">{1}</span>' -f $(if ($scan.Security.Antivirus.EffectiveRealtimeProtection) { 'state-ok' } else { 'state-crit' }), $scan.Security.Antivirus.EffectiveRealtimeProtection))
    [void]$sb.Append(('<span class="k">Firewall</span><span class="v {0}">{1}</span>' -f $(if ($scan.Security.FirewallEnabled) { 'state-ok' } else { 'state-crit' }), $(if ($scan.Security.FirewallEnabled) { 'Enabled' } else { 'DISABLED' })))
    $blOn = $false
    if ($scan.Security.BitLocker -and $scan.Security.BitLocker.Count -gt 0) { $blOn = @($scan.Security.BitLocker | Where-Object { ([string]$_.ProtectionStatus) -match 'On|1' }).Count -gt 0 }
    [void]$sb.Append(('<span class="k">BitLocker</span><span class="v">{0}</span>' -f $(if ($blOn) { 'On' } else { 'Off' })))
    [void]$sb.Append('</div></section>')

    # -- License --------------------------------------------------------------
    if ($scan.License) {
        [void]$sb.Append('<section><h2>Windows License</h2><div class="kv">')
        $l = $scan.License
        $licClass = if ($l.ActivationStatus -eq 'Activated') { 'state-ok' } else { 'state-warn' }
        [void]$sb.Append(('<span class="k">Status</span><span class="v {0}">{1}</span>' -f $licClass, $e::HtmlEncode($l.ActivationStatus)))
        [void]$sb.Append(('<span class="k">Type</span><span class="v">{0}</span>' -f $e::HtmlEncode($l.LicenseType)))
        [void]$sb.Append(('<span class="k">Product</span><span class="v">{0}</span>' -f $e::HtmlEncode($l.ProductName)))
        [void]$sb.Append(('<span class="k">Partial Key</span><span class="v">...{0}</span>' -f $e::HtmlEncode($l.PartialProductKey)))
        if ($l.ExpiryDate) { [void]$sb.Append(('<span class="k">Expiry</span><span class="v state-warn">{0}</span>' -f $e::HtmlEncode($l.ExpiryDate))) }
        [void]$sb.Append('</div></section>')
    }

    # -- Health & Events ------------------------------------------------------
    [void]$sb.Append('<section><h2>Health &amp; Events</h2><div class="kv">')
    $h = $scan.Health
    [void]$sb.Append(('<span class="k">BSOD (7 days)</span><span class="v {0}">{1}</span>' -f $(if ($h.BsodRecentCount -gt 0) { 'state-crit' } else { 'state-ok' }), $h.BsodRecentCount))
    [void]$sb.Append(('<span class="k">Critical Events (24h)</span><span class="v {0}">{1}</span>' -f $(if ($h.CriticalLast24Hours -gt 0) { 'state-crit' } else { 'state-ok' }), $h.CriticalLast24Hours))
    [void]$sb.Append(('<span class="k">WU Errors (24h)</span><span class="v {0}">{1}</span>' -f $(if ($h.WindowsUpdateErrorCount24Hours -gt 0) { 'state-warn' } else { 'state-ok' }), $h.WindowsUpdateErrorCount24Hours))
    [void]$sb.Append(('<span class="k">Pending Reboot</span><span class="v {0}">{1}</span>' -f $(if ($h.PendingReboot) { 'state-warn' } else { 'state-ok' }), $h.PendingReboot))
    [void]$sb.Append('</div>')
    if ($h.WindowsUpdateRecentErrors -and $h.WindowsUpdateRecentErrors.Count -gt 0) {
        $wuData = @($h.WindowsUpdateRecentErrors | ForEach-Object { [ordered]@{ Time = $_.Time.ToString('MM-dd HH:mm'); Code = $_.Code; Category = $_.Category; Message = if ($_.Message.Length -gt 80) { $_.Message.Substring(0,80) + '...' } else { $_.Message } } })
        [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $wuData))
    }
    [void]$sb.Append('</section>')

    # -- Network --------------------------------------------------------------
    [void]$sb.Append('<section><h2>Network</h2><div class="kv">')
    [void]$sb.Append(('<span class="k">IPv4</span><span class="v">{0}</span>' -f $scan.Network.IPv4))
    [void]$sb.Append(('<span class="k">Gateway</span><span class="v">{0}</span>' -f $scan.Network.Gateway))
    [void]$sb.Append(('<span class="k">DNS</span><span class="v">{0}</span>' -f ($scan.Network.DnsServers -join ', ')))
    [void]$sb.Append(('<span class="k">Internet</span><span class="v {0}">{1}</span>' -f $(if ($scan.Network.Internet) { 'state-ok' } else { 'state-crit' }), $scan.Network.Internet))
    [void]$sb.Append('</div>')
    if ($scan.NetworkDetail) {
        if ($scan.NetworkDetail.Adapters.Count -gt 0) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">Adapters</h3>')
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.NetworkDetail.Adapters))
        }
        if ($scan.NetworkDetail.WiFi) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">WiFi</h3><div class="kv">')
            $w = $scan.NetworkDetail.WiFi
            [void]$sb.Append(('<span class="k">SSID</span><span class="v">{0}</span>' -f $e::HtmlEncode($w.SSID)))
            [void]$sb.Append(('<span class="k">Signal</span><span class="v">{0}%</span>' -f $w.SignalPercent))
            [void]$sb.Append(('<span class="k">Channel / Band</span><span class="v">{0} / {1}</span>' -f $w.Channel, $w.Band))
            [void]$sb.Append('</div>')
        }
        if ($scan.NetworkDetail.ListeningPorts.Count -gt 0) {
            [void]$sb.Append('<details><summary>Listening Ports ({0})</summary>' -f $scan.NetworkDetail.ListeningPorts.Count)
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.NetworkDetail.ListeningPorts))
            [void]$sb.Append('</details>')
        }
        if ($scan.NetworkDetail.SMBShares.Count -gt 0) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">SMB Shares</h3>')
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.NetworkDetail.SMBShares))
        }
        if ($scan.NetworkDetail.VPNProfiles.Count -gt 0) {
            [void]$sb.Append('<h3 style="color:var(--muted);font-size:0.95em;margin:8px 0 4px">VPN Profiles</h3>')
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.NetworkDetail.VPNProfiles))
        }
    }
    [void]$sb.Append('</section>')

    # -- Drivers --------------------------------------------------------------
    if ($scan.Drivers) {
        [void]$sb.Append('<section><h2>Driver Analysis</h2>')
        if ($scan.Drivers.Problematic.Count -gt 0) {
            [void]$sb.Append(('<h3 style="color:var(--warn);font-size:0.95em;margin:8px 0 4px">Problematic Drivers ({0})</h3>' -f $scan.Drivers.Problematic.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Drivers.Problematic))
        }
        else {
            [void]$sb.Append('<p class="state-ok">No problematic drivers detected.</p>')
        }
        if ($scan.Drivers.Unsigned.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Unsigned Drivers ({0})</summary>' -f $scan.Drivers.Unsigned.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Drivers.Unsigned))
            [void]$sb.Append('</details>')
        }
        if ($scan.Drivers.RecentlyChanged.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Recently Changed Drivers ({0})</summary>' -f $scan.Drivers.RecentlyChanged.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Drivers.RecentlyChanged))
            [void]$sb.Append('</details>')
        }
        [void]$sb.Append('</section>')
    }

    # -- Startup --------------------------------------------------------------
    if ($scan.Startup) {
        [void]$sb.Append('<section><h2>Startup &amp; Boot</h2><div class="kv">')
        [void]$sb.Append(('<span class="k">Last Boot</span><span class="v">{0}</span>' -f $(if ($scan.Startup.LastBootTime) { $scan.Startup.LastBootTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' })))
        [void]$sb.Append(('<span class="k">Boot Duration</span><span class="v">{0}</span>' -f $(if ($scan.Startup.BootDurationMs) { '{0:N0} ms ({1:N1} s)' -f $scan.Startup.BootDurationMs, ($scan.Startup.BootDurationMs / 1000) } else { 'N/A' })))
        [void]$sb.Append('</div>')
        if ($scan.Startup.RunKeyItems.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Registry Run Keys ({0})</summary>' -f $scan.Startup.RunKeyItems.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Startup.RunKeyItems))
            [void]$sb.Append('</details>')
        }
        if ($scan.Startup.StartupFolderItems.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Startup Folder Items ({0})</summary>' -f $scan.Startup.StartupFolderItems.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Startup.StartupFolderItems))
            [void]$sb.Append('</details>')
        }
        if ($scan.Startup.FailedAutoServices.Count -gt 0) {
            [void]$sb.Append(('<h3 style="color:var(--warn);font-size:0.95em;margin:8px 0 4px">Failed Auto-Start Services ({0})</h3>' -f $scan.Startup.FailedAutoServices.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Startup.FailedAutoServices))
        }
        [void]$sb.Append('</section>')
    }

    # -- User Accounts --------------------------------------------------------
    if ($scan.UserAccounts) {
        [void]$sb.Append('<section><h2>User Accounts</h2>')
        [void]$sb.Append(('<p style="color:var(--muted);font-size:0.9em">User profiles on disk: {0}</p>' -f $scan.UserAccounts.ProfileCount))
        if ($scan.UserAccounts.Users.Count -gt 0) {
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.UserAccounts.Users))
        }
        [void]$sb.Append('</section>')
    }

    # -- Printers -------------------------------------------------------------
    if ($scan.Printers) {
        [void]$sb.Append('<section><h2>Printers</h2>')
        [void]$sb.Append(('<p style="color:var(--muted);font-size:0.9em">Default: {0}</p>' -f $e::HtmlEncode($scan.Printers.DefaultPrinter)))
        if ($scan.Printers.Installed.Count -gt 0) {
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Printers.Installed))
        }
        else {
            [void]$sb.Append('<p class="empty">No printers installed.</p>')
        }
        if ($scan.Printers.StuckJobs.Count -gt 0) {
            [void]$sb.Append(('<h3 style="color:var(--warn);font-size:0.95em;margin:8px 0 4px">Stuck Print Jobs ({0})</h3>' -f $scan.Printers.StuckJobs.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Printers.StuckJobs))
        }
        [void]$sb.Append('</section>')
    }

    # -- Software Inventory ---------------------------------------------------
    if ($scan.Software) {
        [void]$sb.Append(('<section><h2>Installed Software ({0})</h2>' -f $scan.Software.Count))
        if ($scan.Software.Items.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Show all {0} programs</summary>' -f $scan.Software.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Software.Items))
            [void]$sb.Append('</details>')
        }
        [void]$sb.Append('</section>')
    }

    # -- Scheduled Tasks ------------------------------------------------------
    if ($scan.ScheduledTasks) {
        [void]$sb.Append('<section><h2>Scheduled Tasks</h2>')
        if ($scan.ScheduledTasks.Failed.Count -gt 0) {
            [void]$sb.Append(('<h3 style="color:var(--warn);font-size:0.95em;margin:8px 0 4px">Failed Tasks ({0})</h3>' -f $scan.ScheduledTasks.Failed.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.ScheduledTasks.Failed))
        }
        if ($scan.ScheduledTasks.NonMicrosoft.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Non-Microsoft Tasks ({0})</summary>' -f $scan.ScheduledTasks.NonMicrosoft.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.ScheduledTasks.NonMicrosoft))
            [void]$sb.Append('</details>')
        }
        if ($scan.ScheduledTasks.RunAsSystem.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Tasks Running as SYSTEM ({0})</summary>' -f $scan.ScheduledTasks.RunAsSystem.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.ScheduledTasks.RunAsSystem))
            [void]$sb.Append('</details>')
        }
        if ($scan.ScheduledTasks.Failed.Count -eq 0 -and $scan.ScheduledTasks.NonMicrosoft.Count -eq 0) {
            [void]$sb.Append('<p class="state-ok">No non-Microsoft or failed tasks detected.</p>')
        }
        [void]$sb.Append('</section>')
    }

    # -- Virtualization -------------------------------------------------------
    if ($scan.Virtualization) {
        [void]$sb.Append('<section><h2>Virtualization</h2><div class="kv">')
        $v = $scan.Virtualization
        [void]$sb.Append(('<span class="k">Virtual Machine</span><span class="v">{0}</span>' -f $(if ($v.IsVM) { 'Yes ({0})' -f $v.VMPlatform } else { 'No (Physical)' })))
        [void]$sb.Append(('<span class="k">Hyper-V</span><span class="v">{0}</span>' -f $(if ($v.HyperVEnabled -eq $true) { 'Enabled' } elseif ($v.HyperVEnabled -eq $false) { 'Disabled' } else { 'N/A' })))
        if ($v.WSLDistributions.Count -gt 0) {
            [void]$sb.Append(('<span class="k">WSL Distributions</span><span class="v">{0}</span>' -f ($v.WSLDistributions -join ', ')))
        }
        else {
            [void]$sb.Append('<span class="k">WSL</span><span class="v">None</span>')
        }
        [void]$sb.Append('</div></section>')
    }

    # -- Scan Warnings --------------------------------------------------------
    if ($scan.Errors.Count -gt 0) {
        [void]$sb.Append('<section><h2>Scan Warnings</h2><ul class="findings-list">')
        foreach ($err in $scan.Errors) {
            [void]$sb.Append(('<li class="bg-warn state-warn">{0}</li>' -f $e::HtmlEncode($err)))
        }
        [void]$sb.Append('</ul></section>')
    }

    # -- Footer ---------------------------------------------------------------
    [void]$sb.Append(('<footer>Generated by WinPulse v1.0 | {0} | {1}</footer>' -f $scan.System.Hostname, $scan.GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$sb.Append('</div></body></html>')

    # Write file
    $target = Join-Path $script:WinPulsePaths.Exports ('report-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $sb.ToString() | Set-Content -Path $target -Encoding UTF8
    Write-Host ("HTML report exported: {0}" -f $target) -ForegroundColor Green

    try { Start-Process $target }
    catch { Write-Host 'Could not open report in browser. File saved.' -ForegroundColor Yellow }

    return $target
}

# -- End HTML Report ----------------------------------------------------------

function Join-WinPulsePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path,

        [Parameter(Mandatory = $true)]
        [string[]]$childpath
    )

    $result = $path
    foreach ($child in $childpath) {
        $result = Join-Path -Path $result -ChildPath $child
    }
    return $result
}

function ConvertTo-WinPulseDateText {
    [CmdletBinding()]
    param(
        [object]$value
    )

    if ($null -eq $value) { return $null }
    try {
        return ([datetime]$value).ToString('o')
    }
    catch {
        return [string]$value
    }
}

function ConvertTo-WinPulseHtmlText {
    [CmdletBinding()]
    param(
        [object]$value
    )

    if ($null -eq $value) { return '' }
    $text = [string]$value
    $text = $text -replace '&', '&amp;'
    $text = $text -replace '<', '&lt;'
    $text = $text -replace '>', '&gt;'
    $text = $text -replace '"', '&quot;'
    $text = $text -replace "'", '&#39;'
    return $text
}

function Get-WinPulseObjectValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$inputobject,

        [Parameter(Mandatory = $true)]
        [string]$name
    )

    if ($inputobject -is [System.Collections.IDictionary]) {
        if ($inputobject.Contains($name)) {
            return $inputobject[$name]
        }
        return $null
    }

    $prop = $inputobject.PSObject.Properties[$name]
    if ($prop) {
        return $prop.Value
    }
    return $null
}

function ConvertTo-WinPulseMigrationHtmlTable {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [array]$data,

        [string[]]$columns
    )

    $rows = @($data)
    if ($rows.Count -eq 0) {
        return '<p class="empty">No data detected.</p>'
    }

    if (-not $columns -or $columns.Count -eq 0) {
        if ($rows[0] -is [System.Collections.IDictionary]) {
            $columns = @($rows[0].Keys)
        }
        else {
            $columns = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')
    foreach ($column in $columns) {
        [void]$sb.Append(('<th>{0}</th>' -f (ConvertTo-WinPulseHtmlText -value $column)))
    }
    [void]$sb.Append('</tr></thead><tbody>')

    foreach ($row in $rows) {
        [void]$sb.Append('<tr>')
        foreach ($column in $columns) {
            $value = Get-WinPulseObjectValue -inputobject $row -name $column
            if ($value -is [array]) {
                $value = ($value -join ', ')
            }
            [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-WinPulseHtmlText -value $value)))
        }
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Add-WinPulseMigrationHtmlKv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$builder,

        [Parameter(Mandatory = $true)]
        [string]$key,

        [object]$value
    )

    [void]$builder.Append(('<span class="k">{0}</span><span class="v">{1}</span>' -f
            (ConvertTo-WinPulseHtmlText -value $key),
            (ConvertTo-WinPulseHtmlText -value $value)))
}

function New-WinPulseCheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$id,

        [Parameter(Mandatory = $true)]
        [string]$category,

        [Parameter(Mandatory = $true)]
        [string]$name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Pass', 'Warning', 'Fail', 'Info')]
        [string]$status,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Low', 'Medium', 'High', 'Critical')]
        [string]$severity,

        [Parameter(Mandatory = $true)]
        [string]$summary,

        [object]$evidence,

        [string]$recommendation = '',

        [bool]$canautofix = $false,

        [string]$fixid = $null
    )

    if ($null -eq $evidence) {
        $evidence = [ordered]@{}
    }

    return [pscustomobject]@{
        Id             = $id
        Category       = $category
        Name           = $name
        Status         = $status
        Severity       = $severity
        Summary        = $summary
        Evidence       = $evidence
        Recommendation = $recommendation
        CanAutoFix     = $canautofix
        FixId          = $fixid
        Timestamp      = (Get-Date).ToString('o')
    }
}

function New-WinPulsePreflightError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$collector,

        [Parameter(Mandatory = $true)]
        [string]$message
    )

    return [pscustomobject]@{
        Collector = $collector
        Message   = $message
        Timestamp = (Get-Date).ToString('o')
    }
}

function Write-WinPulseMigrationLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$level,

        [Parameter(Mandatory = $true)]
        [string]$message
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $message
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Get-WinPulsePathSize {
    [CmdletBinding()]
    param(
        [string]$path
    )

    $result = [ordered]@{
        Exists = $false
        Bytes  = [double]0
        Size   = '0 B'
        Error  = $null
    }

    try {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            return [pscustomobject]$result
        }

        $result['Exists'] = $true
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            $result['Bytes'] = [double]$item.Length
        }
        else {
            $measure = Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            if ($measure -and $measure.Sum) {
                $result['Bytes'] = [double]$measure.Sum
            }
        }
    }
    catch {
        $result['Error'] = $_.Exception.Message
    }

    $result['Size'] = ConvertTo-ReadableSize -bytes ([double]$result['Bytes'])
    return [pscustomobject]$result
}

function ConvertTo-WinPulseFileSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$file
    )

    return [ordered]@{
        Path          = [string]$file.FullName
        Bytes         = [double]$file.Length
        Size          = ConvertTo-ReadableSize -bytes ([double]$file.Length)
        LastWriteTime = ConvertTo-WinPulseDateText -value $file.LastWriteTime
    }
}

function Get-WinPulseSafeComputerName {
    [CmdletBinding()]
    param()

    $name = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [Environment]::MachineName
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'UnknownComputer'
    }
    return ($name -replace '[^A-Za-z0-9_-]', '_')
}

function Get-WinPulseSystemIdentity {
    [CmdletBinding()]
    param()

    $identity = [ordered]@{
        ComputerName      = Get-WinPulseSafeComputerName
        CurrentUser       = if ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
        DomainOrWorkgroup = 'Unknown'
        DomainJoined      = $false
        OSCaption         = 'Unknown'
        OSVersion         = 'Unknown'
        OSBuild           = 'Unknown'
        InstallDate       = $null
        LastBootTime      = $null
        Architecture      = $env:PROCESSOR_ARCHITECTURE
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    }

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computer) {
            $identity['DomainJoined'] = [bool]$computer.PartOfDomain
            if ([bool]$computer.PartOfDomain) {
                $identity['DomainOrWorkgroup'] = [string]$computer.Domain
            }
            elseif ($computer.Workgroup) {
                $identity['DomainOrWorkgroup'] = [string]$computer.Workgroup
            }
            else {
                $identity['DomainOrWorkgroup'] = 'Workgroup'
            }
        }
    }
    catch {
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os) {
            $identity['OSCaption'] = [string]$os.Caption
            $identity['OSVersion'] = [string]$os.Version
            $identity['OSBuild'] = [string]$os.BuildNumber
            $identity['InstallDate'] = ConvertTo-WinPulseDateText -value $os.InstallDate
            $identity['LastBootTime'] = ConvertTo-WinPulseDateText -value $os.LastBootUpTime
            $identity['Architecture'] = [string]$os.OSArchitecture
        }
    }
    catch {
    }

    return [pscustomobject]$identity
}

function Get-WinPulseWindows11Readiness {
    [CmdletBinding()]
    param()

    $firmwareMode = Get-WinPulseFirmwareMode
    $secureBoot = Get-WinPulseSecureBootState -firmwaremode $firmwareMode
    $pendingReboot = Test-WinPulsePendingReboot
    $tpm = [pscustomobject](Get-WinPulseTPMStatus)

    $ramBytes = [double]0
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $systemDriveFreeBytes = [double]0
    $cpuModel = 'Unknown'
    $partitionStyle = 'Unknown'
    $unknowns = @()
    $warnings = @()
    $blockers = @()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.TotalVisibleMemorySize) {
            $ramBytes = [double]$os.TotalVisibleMemorySize * 1KB
        }
        else {
            $unknowns += 'RAM size unavailable'
        }
    }
    catch {
        $unknowns += 'RAM size unavailable'
    }

    try {
        $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $systemDrive) -ErrorAction Stop
        if ($logicalDisk -and $logicalDisk.FreeSpace) {
            $systemDriveFreeBytes = [double]$logicalDisk.FreeSpace
        }
        else {
            $unknowns += 'System drive free space unavailable'
        }
    }
    catch {
        $unknowns += 'System drive free space unavailable'
    }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu -and $cpu.Name) {
            $cpuModel = ([string]$cpu.Name).Trim()
        }
        else {
            $unknowns += 'CPU model unavailable'
        }
    }
    catch {
        $unknowns += 'CPU model unavailable'
    }

    try {
        if (Get-Command -Name Get-Partition -ErrorAction SilentlyContinue) {
            $driveLetter = ($systemDrive -replace ':', '')
            $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($partition -and (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue)) {
                $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue
                if ($disk -and $disk.PartitionStyle) {
                    $partitionStyle = [string]$disk.PartitionStyle
                }
            }
        }
        if ($partitionStyle -eq 'Unknown') {
            $unknowns += 'Disk partition style unavailable'
        }
    }
    catch {
        $unknowns += 'Disk partition style unavailable'
    }

    if (-not $tpm.Present) {
        $blockers += 'TPM not present'
    }
    elseif (-not $tpm.Enabled) {
        $blockers += 'TPM present but not ready'
    }
    elseif (-not ($tpm.Version -like '2.*' -or $tpm.Version -eq '2.0')) {
        $blockers += ('TPM version {0} is below 2.0 or unknown' -f $tpm.Version)
    }

    if ($firmwareMode -eq 'BIOS') {
        $blockers += 'Legacy BIOS firmware detected'
    }
    elseif ($firmwareMode -eq 'Unknown') {
        $unknowns += 'Firmware mode unavailable'
    }

    if ($secureBoot -eq 'Off') {
        $warnings += 'Secure Boot is off'
    }
    elseif ($secureBoot -eq 'Unknown') {
        $unknowns += 'Secure Boot state unavailable'
    }

    if ($ramBytes -gt 0 -and $ramBytes -lt 4GB) {
        $blockers += 'RAM below 4 GB'
    }

    if ($systemDriveFreeBytes -gt 0 -and $systemDriveFreeBytes -lt 20GB) {
        $warnings += 'System drive has less than 20 GB free'
    }

    if ($partitionStyle -eq 'MBR') {
        $warnings += 'System disk appears to use MBR partitioning'
    }

    if ($pendingReboot) {
        $warnings += 'Pending reboot detected'
    }

    $recommendation = 'Ready'
    if ($blockers.Count -gt 0) {
        $recommendation = 'Not ready'
    }
    elseif ($warnings.Count -gt 0) {
        $recommendation = 'Needs attention'
    }
    elseif ($unknowns.Count -gt 0) {
        $recommendation = 'Unknown'
    }

    return [pscustomobject][ordered]@{
        Recommendation        = $recommendation
        TPM                   = [pscustomobject][ordered]@{
            Present      = [bool]$tpm.Present
            Ready        = [bool]$tpm.Enabled
            SpecVersion  = [string]$tpm.Version
            Manufacturer = [string]$tpm.Manufacturer
        }
        SecureBootState       = $secureBoot
        FirmwareMode          = $firmwareMode
        RamBytes              = $ramBytes
        RamSize               = ConvertTo-ReadableSize -bytes $ramBytes
        SystemDrive           = $systemDrive
        SystemDriveFreeBytes  = $systemDriveFreeBytes
        SystemDriveFree       = ConvertTo-ReadableSize -bytes $systemDriveFreeBytes
        CPUModel              = $cpuModel
        DiskPartitionStyle    = $partitionStyle
        PendingReboot         = [bool]$pendingReboot
        Blockers              = $blockers
        Warnings              = $warnings
        Unknowns              = $unknowns
        Note                  = 'CPU model is collected, but the Microsoft supported CPU list is not validated in this milestone.'
    }
}

function Get-WinPulseMigrationProfiles {
    [CmdletBinding()]
    param(
        [string]$root = 'C:\Users'
    )

    $profiles = @()
    $usersRoot = if ([string]::IsNullOrWhiteSpace($root)) { 'C:\Users' } else { $root }
    $excludeNames = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0', 'WDAGUtilityAccount')

    if (-not (Test-Path -LiteralPath $usersRoot)) {
        return @()
    }

    foreach ($profile in (Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $excludeNames })) {
        $desktop = Join-Path -Path $profile.FullName -ChildPath 'Desktop'
        $documents = Join-Path -Path $profile.FullName -ChildPath 'Documents'
        $downloads = Join-Path -Path $profile.FullName -ChildPath 'Downloads'
        $pictures = Join-Path -Path $profile.FullName -ChildPath 'Pictures'
        $videos = Join-Path -Path $profile.FullName -ChildPath 'Videos'
        $music = Join-Path -Path $profile.FullName -ChildPath 'Music'
        $appData = Join-Path -Path $profile.FullName -ChildPath 'AppData'

        $totalSize = Get-WinPulsePathSize -path $profile.FullName
        $desktopSize = Get-WinPulsePathSize -path $desktop
        $documentsSize = Get-WinPulsePathSize -path $documents
        $downloadsSize = Get-WinPulsePathSize -path $downloads
        $picturesSize = Get-WinPulsePathSize -path $pictures
        $videosSize = Get-WinPulsePathSize -path $videos
        $musicSize = Get-WinPulsePathSize -path $music
        $appDataSize = Get-WinPulsePathSize -path $appData

        $profiles += [pscustomobject][ordered]@{
            UserName            = $profile.Name
            ProfilePath         = $profile.FullName
            Exists              = $true
            LastWriteTime       = ConvertTo-WinPulseDateText -value $profile.LastWriteTime
            EstimatedTotalBytes = [double]$totalSize.Bytes
            EstimatedTotalSize  = $totalSize.Size
            DesktopBytes        = [double]$desktopSize.Bytes
            DesktopSize         = $desktopSize.Size
            DocumentsBytes      = [double]$documentsSize.Bytes
            DocumentsSize       = $documentsSize.Size
            DownloadsBytes      = [double]$downloadsSize.Bytes
            DownloadsSize       = $downloadsSize.Size
            PicturesBytes       = [double]$picturesSize.Bytes
            PicturesSize        = $picturesSize.Size
            VideosBytes         = [double]$videosSize.Bytes
            VideosSize          = $videosSize.Size
            MusicBytes          = [double]$musicSize.Bytes
            MusicSize           = $musicSize.Size
            AppDataBytes        = [double]$appDataSize.Bytes
            AppDataSize         = $appDataSize.Size
            AppDataNote         = 'Reported separately because AppData can be large and noisy.'
        }
    }

    return @($profiles)
}

function Get-WinPulseOneDriveSignals {
    [CmdletBinding()]
    param(
        [array]$profiles
    )

    $signals = @()
    foreach ($profile in @($profiles)) {
        $oneDrivePaths = @()
        $kfmFolders = @()

        try {
            $oneDriveDirs = @(Get-ChildItem -LiteralPath $profile.ProfilePath -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OneDrive*' })
            foreach ($dir in $oneDriveDirs) {
                $oneDrivePaths += $dir.FullName
                foreach ($folderName in @('Desktop', 'Documents', 'Pictures')) {
                    $candidate = Join-Path -Path $dir.FullName -ChildPath $folderName
                    if (Test-Path -LiteralPath $candidate) {
                        $kfmFolders += $folderName
                    }
                }
            }
        }
        catch {
        }

        $kfmFolders = @($kfmFolders | Sort-Object -Unique)
        $status = 'Not detected'
        if ($kfmFolders.Count -gt 0) {
            $status = 'Likely enabled'
        }
        elseif ($oneDrivePaths.Count -gt 0) {
            $status = 'Unknown'
        }

        $signals += [pscustomobject][ordered]@{
            UserName           = $profile.UserName
            ProfilePath        = $profile.ProfilePath
            OneDrivePaths      = $oneDrivePaths
            OneDrivePathCount  = $oneDrivePaths.Count
            KFMFoldersDetected = $kfmFolders
            PotentialKFMStatus = $status
        }
    }

    return @($signals)
}

function Get-WinPulseEmailDataSignals {
    [CmdletBinding()]
    param(
        [array]$profiles
    )

    $pstFiles = @()
    $ostFiles = @()
    $thunderbirdProfiles = @()

    foreach ($profile in @($profiles)) {
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $profile.ProfilePath -Recurse -Force -File -Filter '*.pst' -ErrorAction SilentlyContinue)) {
                $summary = ConvertTo-WinPulseFileSummary -file $file
                $summary['UserName'] = $profile.UserName
                $pstFiles += [pscustomobject]$summary
            }
        }
        catch {
        }

        try {
            foreach ($file in (Get-ChildItem -LiteralPath $profile.ProfilePath -Recurse -Force -File -Filter '*.ost' -ErrorAction SilentlyContinue)) {
                $summary = ConvertTo-WinPulseFileSummary -file $file
                $summary['UserName'] = $profile.UserName
                $summary['MigrationNote'] = 'OST is usually cache data and not a primary migration target.'
                $ostFiles += [pscustomobject]$summary
            }
        }
        catch {
        }

        try {
            $tbRoot = Join-WinPulsePath -path $profile.ProfilePath -childpath @('AppData', 'Roaming', 'Thunderbird', 'Profiles')
            if (Test-Path -LiteralPath $tbRoot) {
                foreach ($dir in (Get-ChildItem -LiteralPath $tbRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                    $size = Get-WinPulsePathSize -path $dir.FullName
                    $thunderbirdProfiles += [pscustomobject][ordered]@{
                        UserName      = $profile.UserName
                        Path          = $dir.FullName
                        Bytes         = [double]$size.Bytes
                        Size          = $size.Size
                        LastWriteTime = ConvertTo-WinPulseDateText -value $dir.LastWriteTime
                    }
                }
            }
        }
        catch {
        }
    }

    return [pscustomobject][ordered]@{
        PstFiles            = @($pstFiles)
        OstFiles            = @($ostFiles)
        ThunderbirdProfiles = @($thunderbirdProfiles)
        PstCount            = @($pstFiles).Count
        OstCount            = @($ostFiles).Count
        ThunderbirdCount    = @($thunderbirdProfiles).Count
        PstBytes            = [double]((@($pstFiles) | Measure-Object -Property Bytes -Sum).Sum)
        OstBytes            = [double]((@($ostFiles) | Measure-Object -Property Bytes -Sum).Sum)
        OstNote             = 'OST files are detected for awareness, but are usually cache data and not a primary migration target.'
    }
}

function Get-WinPulseBrowserSignals {
    [CmdletBinding()]
    param(
        [array]$profiles
    )

    $browsers = @()
    foreach ($profile in @($profiles)) {
        $targets = @(
            @{ Name = 'Chrome'; Relative = @('AppData', 'Local', 'Google', 'Chrome', 'User Data') },
            @{ Name = 'Edge'; Relative = @('AppData', 'Local', 'Microsoft', 'Edge', 'User Data') },
            @{ Name = 'Firefox'; Relative = @('AppData', 'Roaming', 'Mozilla', 'Firefox', 'Profiles') },
            @{ Name = 'Brave'; Relative = @('AppData', 'Local', 'BraveSoftware', 'Brave-Browser', 'User Data') }
        )

        foreach ($target in $targets) {
            $path = Join-WinPulsePath -path $profile.ProfilePath -childpath $target['Relative']
            $size = Get-WinPulsePathSize -path $path
            $browsers += [pscustomobject][ordered]@{
                UserName = $profile.UserName
                Browser  = $target['Name']
                Path     = $path
                Exists   = [bool]$size.Exists
                Bytes    = [double]$size.Bytes
                Size     = $size.Size
            }
        }
    }

    return @($browsers)
}

function Get-WinPulseNetworkMigrationSignals {
    [CmdletBinding()]
    param(
        [array]$profiles
    )

    $wifiNames = @()
    $netshAvailable = [bool](Get-Command -Name netsh.exe -ErrorAction SilentlyContinue)
    if ($netshAvailable) {
        try {
            $output = & netsh.exe wlan show profiles 2>$null
            foreach ($line in @($output)) {
                $match = [regex]::Match([string]$line, ':\s*(.+)$')
                if ($line -match 'Profile' -and $match.Success) {
                    $name = $match.Groups[1].Value.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $wifiNames += $name
                    }
                }
            }
        }
        catch {
        }
    }

    $vpnPhonebooks = @()
    $programDataPath = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    $globalPbk = Join-WinPulsePath -path $programDataPath -childpath @('Microsoft', 'Network', 'Connections', 'Pbk', 'rasphone.pbk')
    foreach ($candidate in @($globalPbk)) {
        $size = Get-WinPulsePathSize -path $candidate
        if ($size.Exists) {
            $vpnPhonebooks += [pscustomobject][ordered]@{
                Scope = 'ProgramData'
                UserName = $null
                Path = $candidate
                Exists = $true
                Bytes = [double]$size.Bytes
                Size = $size.Size
            }
        }
    }

    foreach ($profile in @($profiles)) {
        $candidate = Join-WinPulsePath -path $profile.ProfilePath -childpath @('AppData', 'Roaming', 'Microsoft', 'Network', 'Connections', 'Pbk', 'rasphone.pbk')
        $size = Get-WinPulsePathSize -path $candidate
        if ($size.Exists) {
            $vpnPhonebooks += [pscustomobject][ordered]@{
                Scope = 'User'
                UserName = $profile.UserName
                Path = $candidate
                Exists = $true
                Bytes = [double]$size.Bytes
                Size = $size.Size
            }
        }
    }

    return [pscustomobject][ordered]@{
        NetshAvailable     = $netshAvailable
        WiFiProfilesExist  = (@($wifiNames).Count -gt 0)
        WiFiProfileNames   = @($wifiNames | Sort-Object -Unique)
        WiFiProfileCount   = @($wifiNames | Sort-Object -Unique).Count
        WiFiCredentialNote = 'Preflight lists Wi-Fi profile names only. Keys are not exported.'
        VpnPhonebooks      = @($vpnPhonebooks)
        VpnPhonebookCount  = @($vpnPhonebooks).Count
        VpnCredentialNote  = 'VPN phonebook files are detected only. Credentials are not exported.'
    }
}

function Get-WinPulseMigrationApplicationInventory {
    [CmdletBinding()]
    param()

    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $seen = @{}
    $items = @()
    foreach ($regPath in $regPaths) {
        try {
            foreach ($entry in (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue)) {
                $displayName = if ($entry.PSObject.Properties['DisplayName']) { [string]$entry.PSObject.Properties['DisplayName'].Value } else { $null }
                if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

                $displayVersion = if ($entry.PSObject.Properties['DisplayVersion']) { [string]$entry.PSObject.Properties['DisplayVersion'].Value } else { '' }
                $publisher = if ($entry.PSObject.Properties['Publisher']) { [string]$entry.PSObject.Properties['Publisher'].Value } else { '' }
                $installLocation = if ($entry.PSObject.Properties['InstallLocation']) { [string]$entry.PSObject.Properties['InstallLocation'].Value } else { '' }
                $hasUninstallString = ($null -ne $entry.PSObject.Properties['UninstallString'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.PSObject.Properties['UninstallString'].Value))

                $dedupeKey = '{0}|{1}|{2}' -f $displayName, $displayVersion, $publisher
                if ($seen.ContainsKey($dedupeKey)) { continue }
                $seen[$dedupeKey] = $true

                $items += [pscustomobject][ordered]@{
                    DisplayName        = $displayName
                    DisplayVersion     = if ($displayVersion) { $displayVersion } else { 'N/A' }
                    Publisher          = if ($publisher) { $publisher } else { 'N/A' }
                    InstallLocation    = if ($installLocation) { $installLocation } else { 'N/A' }
                    HasUninstallString = [bool]$hasUninstallString
                }
            }
        }
        catch {
        }
    }

    $wingetCommand = Get-Command -Name winget.exe, winget -ErrorAction SilentlyContinue | Select-Object -First 1
    return [pscustomobject][ordered]@{
        Items             = @($items | Sort-Object DisplayName)
        Count             = @($items).Count
        WingetAvailable   = [bool]$wingetCommand
        WingetPath        = if ($wingetCommand) { [string]$wingetCommand.Source } else { $null }
        WingetListRun     = $false
        WingetListNote    = 'winget list is not run by default in this preflight milestone to keep collection predictable.'
    }
}

function Invoke-WinPulseBackupAppCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$destinationRoot
    )

    $capture = [ordered]@{
        WingetAvailable     = $false
        WingetExportFile    = $null
        WingetExportExitCode = $null
        InventoryFile       = $null
        Note                = 'App capture was not attempted.'
    }

    try {
        $appsRoot = Join-Path -Path $destinationRoot -ChildPath 'apps'
        New-Item -Path $appsRoot -ItemType Directory -Force | Out-Null

        try {
            $inventory = Get-WinPulseMigrationApplicationInventory
            $inventoryPath = Join-Path -Path $appsRoot -ChildPath 'installed-apps.json'
            $inventory | ConvertTo-Json -Depth 6 | Set-Content -Path $inventoryPath -Encoding UTF8
            $capture['InventoryFile'] = 'apps\installed-apps.json'
            $capture['WingetAvailable'] = [bool]$inventory.WingetAvailable
        }
        catch {
            $capture['Note'] = ('Installed app inventory failed: {0}' -f $_.Exception.Message)
        }

        $wingetCommand = Get-Command -Name winget.exe, winget -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $wingetCommand) {
            $capture['WingetAvailable'] = $false
            if ([string]::IsNullOrWhiteSpace([string]$capture['Note']) -or [string]$capture['Note'] -eq 'App capture was not attempted.') {
                $capture['Note'] = 'Installed app inventory captured; winget was not available for export.'
            }
            return [pscustomobject]$capture
        }

        $capture['WingetAvailable'] = $true
        $wingetExportPath = Join-Path -Path $appsRoot -ChildPath 'winget-packages.json'
        try {
            $wingetPath = [string]$wingetCommand.Source
            $wingetOutput = & $wingetPath export -o $wingetExportPath --accept-source-agreements 2>&1
            $capture['WingetExportExitCode'] = $LASTEXITCODE
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $wingetExportPath)) {
                $capture['WingetExportFile'] = 'apps\winget-packages.json'
                $capture['Note'] = 'Installed app inventory captured; winget export completed.'
            }
            else {
                $capture['Note'] = ('Installed app inventory captured; winget export failed with exit code {0}: {1}' -f $LASTEXITCODE, (($wingetOutput | Out-String).Trim()))
            }
        }
        catch {
            $capture['Note'] = ('Installed app inventory captured; winget export failed: {0}' -f $_.Exception.Message)
        }
    }
    catch {
        $capture['Note'] = ('App capture failed: {0}' -f $_.Exception.Message)
    }

    return [pscustomobject]$capture
}

function Get-WinPulseDeveloperHints {
    [CmdletBinding()]
    param(
        [array]$profiles
    )

    $hints = @()
    $relativeTargets = @(
        @{ Label = '.ssh'; Relative = @('.ssh') },
        @{ Label = '.gitconfig'; Relative = @('.gitconfig') },
        @{ Label = '.aws'; Relative = @('.aws') },
        @{ Label = '.azure'; Relative = @('.azure') },
        @{ Label = '.kube'; Relative = @('.kube') },
        @{ Label = '.docker'; Relative = @('.docker') },
        @{ Label = '.npmrc'; Relative = @('.npmrc') },
        @{ Label = '.wslconfig'; Relative = @('.wslconfig') },
        @{ Label = 'VS Code user settings'; Relative = @('AppData', 'Roaming', 'Code', 'User', 'settings.json') },
        @{ Label = 'Windows Terminal settings'; Relative = @('AppData', 'Local', 'Packages', 'Microsoft.WindowsTerminal_8wekyb3d8bbwe', 'LocalState', 'settings.json') },
        @{ Label = 'Windows Terminal Preview settings'; Relative = @('AppData', 'Local', 'Packages', 'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe', 'LocalState', 'settings.json') }
    )

    foreach ($profile in @($profiles)) {
        foreach ($target in $relativeTargets) {
            $path = Join-WinPulsePath -path $profile.ProfilePath -childpath $target['Relative']
            $size = Get-WinPulsePathSize -path $path
            $hints += [pscustomobject][ordered]@{
                UserName = $profile.UserName
                Item     = $target['Label']
                Path     = $path
                Exists   = [bool]$size.Exists
                Bytes    = [double]$size.Bytes
                Size     = $size.Size
            }
        }
    }

    return @($hints)
}

function New-WinPulseMigrationRiskSummary {
    [CmdletBinding()]
    param(
        [array]$profiles,
        [array]$oneDrive,
        [pscustomobject]$email,
        [array]$browsers,
        [pscustomobject]$network,
        [pscustomobject]$applications,
        [pscustomobject]$windows11Readiness
    )

    $profileRows = @($profiles)
    $totalUserBytes = [double]0
    foreach ($profile in $profileRows) {
        $totalUserBytes += [double]$profile.EstimatedTotalBytes
    }

    $largeProfiles = @($profileRows | Where-Object { [double]$_.EstimatedTotalBytes -ge 50GB })
    $pstCount = if ($email) { [int]$email.PstCount } else { 0 }
    $ostCount = if ($email) { [int]$email.OstCount } else { 0 }
    $oneDriveLikelyCount = @(@($oneDrive) | Where-Object { $_.PotentialKFMStatus -eq 'Likely enabled' }).Count
    $browserProfilesFound = @(@($browsers) | Where-Object { $_.Exists }).Count
    $vpnProfilesFound = if ($network) { [int]$network.VpnPhonebookCount } else { 0 }
    $wifiProfilesFound = if ($network) { [int]$network.WiFiProfileCount } else { 0 }
    $wingetAvailable = if ($applications) { [bool]$applications.WingetAvailable } else { $false }
    $readinessStatus = if ($windows11Readiness) { $windows11Readiness.Recommendation } else { 'Unknown' }
    $pendingReboot = if ($windows11Readiness) { [bool]$windows11Readiness.PendingReboot } else { $false }

    $approach = 'Needs manual review'
    if ($readinessStatus -eq 'Unknown') {
        $approach = 'Not enough information'
    }
    elseif ($readinessStatus -eq 'Ready' -and $largeProfiles.Count -eq 0 -and $pstCount -eq 0 -and $oneDriveLikelyCount -gt 0) {
        $approach = 'In-place upgrade'
    }
    elseif ($readinessStatus -eq 'Not ready' -or $largeProfiles.Count -gt 0 -or $pstCount -gt 0) {
        $approach = 'Clean install with backup/restore'
    }

    return [pscustomobject][ordered]@{
        TotalEstimatedUserDataBytes = $totalUserBytes
        TotalEstimatedUserDataSize  = ConvertTo-ReadableSize -bytes $totalUserBytes
        UserProfileCount            = $profileRows.Count
        LargeProfileThreshold       = '50 GB'
        LargeProfiles               = @($largeProfiles | ForEach-Object { $_.UserName })
        PstFilesFound               = $pstCount
        OstFilesFound               = $ostCount
        OneDriveKFMLikelyEnabled    = $oneDriveLikelyCount
        BrowserProfilesFound        = $browserProfilesFound
        VpnProfilesFound            = $vpnProfilesFound
        WiFiProfilesFound           = $wifiProfilesFound
        WingetAvailable             = $wingetAvailable
        Windows11ReadinessStatus    = $readinessStatus
        PendingReboot               = $pendingReboot
        RecommendedMigrationApproach = $approach
    }
}

function Export-WinPulseMigrationPreflightJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$report,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $report | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
}

function Export-WinPulseMigrationPreflightText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$report,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $computer = $report.Computer
    $readiness = $report.Windows11Readiness
    $migration = $report.Migration
    $risk = $migration.RiskSummary
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('WinPulse Migration Preflight')
    $lines.Add(('Generated: {0}' -f $report.Tool.GeneratedAt))
    $lines.Add('')
    $lines.Add(('Machine: {0}' -f $computer.ComputerName))
    $lines.Add(('User: {0}' -f $computer.CurrentUser))
    $lines.Add(('OS: {0} {1} (Build {2})' -f $computer.OSCaption, $computer.OSVersion, $computer.OSBuild))
    $lines.Add(('Domain/Workgroup: {0}' -f $computer.DomainOrWorkgroup))
    $lines.Add('')
    $lines.Add(('Windows 11 readiness: {0}' -f $readiness.Recommendation))
    $lines.Add(('TPM: present={0}, ready={1}, version={2}' -f $readiness.TPM.Present, $readiness.TPM.Ready, $readiness.TPM.SpecVersion))
    $lines.Add(('Secure Boot: {0}' -f $readiness.SecureBootState))
    $lines.Add(('Firmware: {0}' -f $readiness.FirmwareMode))
    $lines.Add(('RAM: {0}' -f $readiness.RamSize))
    $lines.Add(('System drive free: {0}' -f $readiness.SystemDriveFree))
    $lines.Add('')
    $lines.Add('User profiles:')
    foreach ($profile in @($migration.Profiles)) {
        $lines.Add(('- {0}: {1} total | Desktop {2} | Documents {3} | Downloads {4}' -f
                $profile.UserName, $profile.EstimatedTotalSize, $profile.DesktopSize, $profile.DocumentsSize, $profile.DownloadsSize))
    }
    if (@($migration.Profiles).Count -eq 0) {
        $lines.Add('- No user profiles detected under C:\Users.')
    }
    $lines.Add('')
    $lines.Add('Major risks:')
    $largeProfileText = if ($risk.LargeProfiles.Count -gt 0) { $risk.LargeProfiles -join ', ' } else { 'none' }
    $lines.Add(('- Total estimated user data: {0}' -f $risk.TotalEstimatedUserDataSize))
    $lines.Add(('- Large profiles: {0}' -f $largeProfileText))
    $lines.Add(('- PST files: {0}' -f $risk.PstFilesFound))
    $lines.Add(('- OST files: {0} (usually cache, not primary migration target)' -f $risk.OstFilesFound))
    $lines.Add(('- OneDrive/KFM likely enabled profiles: {0}' -f $risk.OneDriveKFMLikelyEnabled))
    $lines.Add(('- Browser profiles found: {0}' -f $risk.BrowserProfilesFound))
    $lines.Add(('- VPN phonebooks found: {0}' -f $risk.VpnProfilesFound))
    $lines.Add(('- Wi-Fi profiles found: {0}' -f $risk.WiFiProfilesFound))
    $lines.Add(('- winget available: {0}' -f $risk.WingetAvailable))
    $lines.Add(('- Pending reboot: {0}' -f $risk.PendingReboot))
    $lines.Add('')
    $lines.Add(('Recommended next action: {0}' -f $risk.RecommendedMigrationApproach))
    $lines.Add('')
    $lines.Add('Notes:')
    $lines.Add('- Preflight is read-only.')
    $lines.Add('- Wi-Fi keys, VPN credentials, browser passwords, DPAPI secrets, and private keys are not exported.')
    $lines.Add('- See migration-preflight.json for full machine-readable details.')

    $lines | Set-Content -Path $path -Encoding UTF8
}

function Export-WinPulseMigrationPreflightHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$report,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $computer = $report.Computer
    $readiness = $report.Windows11Readiness
    $migration = $report.Migration
    $risk = $migration.RiskSummary
    $checks = @($report.Checks)
    $warnings = @($checks | Where-Object { $_.Status -ne 'Pass' })

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WinPulse Migration Preflight</title>
<style>
:root{--bg:#111827;--panel:#182233;--panel2:#101826;--border:#334155;--text:#e5e7eb;--muted:#94a3b8;--ok:#22c55e;--warn:#f59e0b;--crit:#ef4444;--info:#38bdf8}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Tahoma,sans-serif;line-height:1.45}
.container{max-width:1180px;margin:0 auto;padding:24px}
header{border-bottom:2px solid var(--border);padding-bottom:18px;margin-bottom:18px}
h1{font-size:1.8rem;margin:0 0 6px;color:var(--info)}
h2{font-size:1.05rem;margin:0 0 10px;color:var(--info)}
h3{font-size:.92rem;margin:14px 0 6px;color:var(--muted)}
section{background:var(--panel);border:1px solid var(--border);border-radius:6px;padding:16px;margin:0 0 14px}
.subtitle,.empty,footer{color:var(--muted)}
.badge{display:inline-block;border:1px solid var(--border);border-radius:4px;padding:4px 9px;margin:4px 8px 4px 0;font-weight:600}
.ready{color:var(--ok);border-color:var(--ok)}.attention{color:var(--warn);border-color:var(--warn)}.notready{color:var(--crit);border-color:var(--crit)}.unknown{color:var(--muted)}
.kv{display:grid;grid-template-columns:minmax(180px,260px) 1fr;gap:5px 18px}
.k{color:var(--muted);font-weight:600}.v{color:var(--text)}
table{width:100%;border-collapse:collapse;font-size:.86rem}
th{background:var(--panel2);color:var(--muted);text-align:left;padding:7px;border-bottom:1px solid var(--border)}
td{padding:7px;border-bottom:1px solid rgba(148,163,184,.16);vertical-align:top}
tr:hover td{background:rgba(255,255,255,.025)}
ul{margin:0;padding-left:20px}
code{color:var(--info)}
footer{font-size:.8rem;border-top:1px solid var(--border);padding-top:16px;margin-top:18px}
@media print{body{background:#fff;color:#111}.container{max-width:none;padding:10px}section{background:#fff;border-color:#ccc;break-inside:avoid}.subtitle,.empty,footer,.k,th{color:#555}th{background:#eee}.v,td{color:#111}}
</style>
</head>
<body>
<div class="container">
'@)

    $readinessClass = switch ($readiness.Recommendation) {
        'Ready' { 'ready' }
        'Needs attention' { 'attention' }
        'Not ready' { 'notready' }
        default { 'unknown' }
    }

    [void]$sb.Append(('<header><h1>WinPulse Migration Preflight</h1><div class="subtitle">{0} | {1} | WinPulse {2}</div>' -f
            (ConvertTo-WinPulseHtmlText -value $computer.ComputerName),
            (ConvertTo-WinPulseHtmlText -value $report.Tool.GeneratedAt),
            (ConvertTo-WinPulseHtmlText -value $report.Tool.Version)))
    [void]$sb.Append(('<div class="badge {0}">Windows 11: {1}</div>' -f $readinessClass, (ConvertTo-WinPulseHtmlText -value $readiness.Recommendation)))
    [void]$sb.Append(('<div class="badge">Approach: {0}</div></header>' -f (ConvertTo-WinPulseHtmlText -value $risk.RecommendedMigrationApproach)))

    [void]$sb.Append('<section><h2>Executive Summary</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Machine' -value $computer.ComputerName
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'OS' -value ('{0} {1} (Build {2})' -f $computer.OSCaption, $computer.OSVersion, $computer.OSBuild)
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Profiles' -value $risk.UserProfileCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Estimated user data' -value $risk.TotalEstimatedUserDataSize
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'PST / OST files' -value ('{0} / {1}' -f $risk.PstFilesFound, $risk.OstFilesFound)
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Recommended approach' -value $risk.RecommendedMigrationApproach
    [void]$sb.Append('</div></section>')

    [void]$sb.Append('<section><h2>Windows 11 Readiness</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Recommendation' -value $readiness.Recommendation
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'TPM' -value ('present={0}, ready={1}, version={2}' -f $readiness.TPM.Present, $readiness.TPM.Ready, $readiness.TPM.SpecVersion)
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Secure Boot' -value $readiness.SecureBootState
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Firmware' -value $readiness.FirmwareMode
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'RAM' -value $readiness.RamSize
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'System drive free' -value $readiness.SystemDriveFree
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'CPU' -value $readiness.CPUModel
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Partition style' -value $readiness.DiskPartitionStyle
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Pending reboot' -value $readiness.PendingReboot
    [void]$sb.Append('</div>')
    if ($readiness.Blockers.Count -gt 0) { [void]$sb.Append(('<h3>Blockers</h3><p>{0}</p>' -f (ConvertTo-WinPulseHtmlText -value ($readiness.Blockers -join '; ')))) }
    if ($readiness.Warnings.Count -gt 0) { [void]$sb.Append(('<h3>Warnings</h3><p>{0}</p>' -f (ConvertTo-WinPulseHtmlText -value ($readiness.Warnings -join '; ')))) }
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Migration Risk Summary</h2><div class="kv">')
    foreach ($prop in @('TotalEstimatedUserDataSize', 'UserProfileCount', 'LargeProfiles', 'PstFilesFound', 'OstFilesFound', 'OneDriveKFMLikelyEnabled', 'BrowserProfilesFound', 'VpnProfilesFound', 'WiFiProfilesFound', 'WingetAvailable', 'Windows11ReadinessStatus', 'PendingReboot', 'RecommendedMigrationApproach')) {
        $value = Get-WinPulseObjectValue -inputobject $risk -name $prop
        if ($value -is [array]) { $value = if ($value.Count -gt 0) { $value -join ', ' } else { 'none' } }
        Add-WinPulseMigrationHtmlKv -builder $sb -key $prop -value $value
    }
    [void]$sb.Append('</div></section>')

    [void]$sb.Append('<section><h2>User Profiles</h2>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.Profiles -columns @('UserName', 'ProfilePath', 'EstimatedTotalSize', 'DesktopSize', 'DocumentsSize', 'DownloadsSize', 'PicturesSize', 'VideosSize', 'MusicSize', 'AppDataSize')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>OneDrive/Known Folder Move Signals</h2>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.OneDrive -columns @('UserName', 'OneDrivePathCount', 'KFMFoldersDetected', 'PotentialKFMStatus')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Email Data</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'PST files' -value $migration.Email.PstCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'OST files' -value $migration.Email.OstCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Thunderbird profiles' -value $migration.Email.ThunderbirdCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'OST note' -value $migration.Email.OstNote
    [void]$sb.Append('</div><h3>PST Files</h3>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.Email.PstFiles -columns @('UserName', 'Path', 'Size', 'LastWriteTime')))
    [void]$sb.Append('<h3>OST Files</h3>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.Email.OstFiles -columns @('UserName', 'Path', 'Size', 'MigrationNote')))
    [void]$sb.Append('<h3>Thunderbird Profiles</h3>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.Email.ThunderbirdProfiles -columns @('UserName', 'Path', 'Size', 'LastWriteTime')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Browsers</h2>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.Browsers -columns @('UserName', 'Browser', 'Exists', 'Size', 'Path')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Network Profiles</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Wi-Fi profiles' -value $migration.Network.WiFiProfileCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Wi-Fi names' -value ($migration.Network.WiFiProfileNames -join ', ')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'VPN phonebooks' -value $migration.Network.VpnPhonebookCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Credential note' -value $migration.Network.WiFiCredentialNote
    [void]$sb.Append('</div>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $migration.Network.VpnPhonebooks -columns @('Scope', 'UserName', 'Path', 'Size')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Application Inventory Summary</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Installed applications' -value $migration.Applications.Count
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'winget available' -value $migration.Applications.WingetAvailable
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'winget note' -value $migration.Applications.WingetListNote
    [void]$sb.Append('</div><h3>Installed Applications</h3>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data (@($migration.Applications.Items) | Select-Object -First 150) -columns @('DisplayName', 'DisplayVersion', 'Publisher', 'InstallLocation', 'HasUninstallString')))
    if ($migration.Applications.Count -gt 150) {
        [void]$sb.Append(('<p class="empty">Showing first 150 applications. Full list is in migration-preflight.json.</p>'))
    }
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Developer/Config Hints</h2>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data (@($migration.DeveloperHints) | Where-Object { $_.Exists }) -columns @('UserName', 'Item', 'Exists', 'Size', 'Path')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Errors/Warnings</h2>')
    if ($warnings.Count -eq 0 -and @($report.Errors).Count -eq 0) {
        [void]$sb.Append('<p class="ready">No collection warnings recorded.</p>')
    }
    else {
        [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $warnings -columns @('Id', 'Status', 'Severity', 'Summary', 'Recommendation')))
        if (@($report.Errors).Count -gt 0) {
            [void]$sb.Append('<h3>Collector Errors</h3>')
            [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $report.Errors -columns @('Collector', 'Message', 'Timestamp')))
        }
    }
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Raw Details</h2><p>Machine-readable data is saved next to this report as <code>migration-preflight.json</code>.</p></section>')
    [void]$sb.Append(('<footer>Generated by WinPulse {0}</footer>' -f (ConvertTo-WinPulseHtmlText -value $report.Tool.Version)))
    [void]$sb.Append('</div></body></html>')

    $sb.ToString() | Set-Content -Path $path -Encoding UTF8
}

function Invoke-WinPulseMigrationPreflight {
    [CmdletBinding()]
    param()

    $computerName = Get-WinPulseSafeComputerName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $exportFolder = Join-Path -Path $script:WinPulsePaths.Exports -ChildPath ('MigrationPreflight-{0}-{1}' -f $computerName, $stamp)
    $logFolder = Join-Path -Path $exportFolder -ChildPath 'logs'
    New-Item -Path $logFolder -ItemType Directory -Force | Out-Null

    $jsonPath = Join-Path -Path $exportFolder -ChildPath 'migration-preflight.json'
    $htmlPath = Join-Path -Path $exportFolder -ChildPath 'migration-preflight.html'
    $textPath = Join-Path -Path $exportFolder -ChildPath 'migration-preflight.txt'
    $logPath = Join-Path -Path $logFolder -ChildPath 'migration-preflight.log'

    Write-WinPulseHeader -title 'Migration Preflight'
    Write-Host '  Read-only collection. No files, credentials, keys, or browser secrets will be exported.' -ForegroundColor Cyan
    Write-Host ('  Output: {0}' -f $exportFolder) -ForegroundColor Gray
    Write-Host ''
    Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message 'Migration preflight started.'

    $checks = @()
    $errors = @()

    $computer = $null
    try {
        Write-Host '  Collecting system identity...' -ForegroundColor Gray
        $computer = Get-WinPulseSystemIdentity
        $checks += New-WinPulseCheckResult -id 'Migration.SystemIdentity' -category 'Migration' -name 'System identity' -status 'Pass' -severity 'Low' -summary ('Collected identity for {0}.' -f $computer.ComputerName) -recommendation 'Use this to identify the exported report folder.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'SystemIdentity' -message $_.Exception.Message
        $computer = [pscustomobject][ordered]@{ ComputerName = $computerName; CurrentUser = ''; DomainOrWorkgroup = 'Unknown'; OSCaption = 'Unknown'; OSVersion = 'Unknown'; OSBuild = 'Unknown' }
        $checks += New-WinPulseCheckResult -id 'Migration.SystemIdentity' -category 'Migration' -name 'System identity' -status 'Fail' -severity 'Medium' -summary 'System identity collection failed.' -recommendation 'Review log and run elevated if needed.'
    }

    $readiness = $null
    try {
        Write-Host '  Collecting Windows 11 readiness signals...' -ForegroundColor Gray
        $readiness = Get-WinPulseWindows11Readiness
        $status = if ($readiness.Recommendation -eq 'Ready') { 'Pass' } elseif ($readiness.Recommendation -eq 'Not ready') { 'Fail' } else { 'Warning' }
        $severity = if ($status -eq 'Fail') { 'High' } elseif ($status -eq 'Warning') { 'Medium' } else { 'Low' }
        $checks += New-WinPulseCheckResult -id 'Migration.Windows11Readiness' -category 'Readiness' -name 'Windows 11 readiness' -status $status -severity $severity -summary ('Windows 11 readiness: {0}.' -f $readiness.Recommendation) -evidence $readiness -recommendation 'Review blockers and warnings before upgrade planning.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'Windows11Readiness' -message $_.Exception.Message
        $readiness = [pscustomobject][ordered]@{ Recommendation = 'Unknown'; PendingReboot = $false; TPM = [pscustomobject][ordered]@{ Present = $false; Ready = $false; SpecVersion = 'Unknown' }; Blockers = @(); Warnings = @(); Unknowns = @('Readiness collection failed') }
        $checks += New-WinPulseCheckResult -id 'Migration.Windows11Readiness' -category 'Readiness' -name 'Windows 11 readiness' -status 'Warning' -severity 'Medium' -summary 'Windows 11 readiness collection failed.' -recommendation 'Validate readiness manually.'
    }

    $profiles = @()
    try {
        Write-Host '  Scanning user profiles and known folders...' -ForegroundColor Gray
        $profiles = @(Get-WinPulseMigrationProfiles)
        $checks += New-WinPulseCheckResult -id 'Migration.ProfileScan' -category 'Migration' -name 'User profile scan' -status 'Pass' -severity 'Low' -summary ('Found {0} user profiles.' -f $profiles.Count) -evidence ([ordered]@{ Count = $profiles.Count }) -recommendation 'Review large profiles before backup.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'Profiles' -message $_.Exception.Message
        $checks += New-WinPulseCheckResult -id 'Migration.ProfileScan' -category 'Migration' -name 'User profile scan' -status 'Fail' -severity 'High' -summary 'User profile scan failed.' -recommendation 'Check profile permissions and rerun.'
    }

    $oneDrive = @()
    try {
        Write-Host '  Detecting OneDrive/KFM signals...' -ForegroundColor Gray
        $oneDrive = @(Get-WinPulseOneDriveSignals -profiles $profiles)
        $likelyCount = @($oneDrive | Where-Object { $_.PotentialKFMStatus -eq 'Likely enabled' }).Count
        $checks += New-WinPulseCheckResult -id 'Migration.OneDriveKFM' -category 'Migration' -name 'OneDrive/KFM detection' -status 'Info' -severity 'Low' -summary ('OneDrive/KFM likely enabled for {0} profiles.' -f $likelyCount) -recommendation 'Verify cloud sync health before wiping or reinstalling.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'OneDrive' -message $_.Exception.Message
        $checks += New-WinPulseCheckResult -id 'Migration.OneDriveKFM' -category 'Migration' -name 'OneDrive/KFM detection' -status 'Warning' -severity 'Medium' -summary 'OneDrive/KFM detection failed.' -recommendation 'Check OneDrive manually.'
    }

    $email = $null
    try {
        Write-Host '  Detecting PST/OST and Thunderbird data...' -ForegroundColor Gray
        $email = Get-WinPulseEmailDataSignals -profiles $profiles
        $emailStatus = if ($email.PstCount -gt 0) { 'Warning' } else { 'Info' }
        $checks += New-WinPulseCheckResult -id 'Migration.EmailData' -category 'Migration' -name 'Email data detection' -status $emailStatus -severity 'Medium' -summary ('Found {0} PST files, {1} OST files, and {2} Thunderbird profiles.' -f $email.PstCount, $email.OstCount, $email.ThunderbirdCount) -recommendation 'Treat PST files as migration targets. OST files are usually cache data.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'Email' -message $_.Exception.Message
        $email = [pscustomobject][ordered]@{ PstFiles = @(); OstFiles = @(); ThunderbirdProfiles = @(); PstCount = 0; OstCount = 0; ThunderbirdCount = 0; PstBytes = 0; OstBytes = 0; OstNote = 'Email collection failed.' }
        $checks += New-WinPulseCheckResult -id 'Migration.EmailData' -category 'Migration' -name 'Email data detection' -status 'Warning' -severity 'Medium' -summary 'Email data detection failed.' -recommendation 'Search for PST files manually.'
    }

    $browsers = @()
    try {
        Write-Host '  Detecting browser profile roots...' -ForegroundColor Gray
        $browsers = @(Get-WinPulseBrowserSignals -profiles $profiles)
        $browserCount = @($browsers | Where-Object { $_.Exists }).Count
        $checks += New-WinPulseCheckResult -id 'Migration.Browsers' -category 'Migration' -name 'Browser profile detection' -status 'Info' -severity 'Low' -summary ('Found {0} browser profile roots.' -f $browserCount) -recommendation 'Do not export browser passwords or DPAPI secrets.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'Browsers' -message $_.Exception.Message
        $checks += New-WinPulseCheckResult -id 'Migration.Browsers' -category 'Migration' -name 'Browser profile detection' -status 'Warning' -severity 'Low' -summary 'Browser profile detection failed.' -recommendation 'Check browser profile paths manually.'
    }

    $network = $null
    try {
        Write-Host '  Detecting Wi-Fi names and VPN phonebooks...' -ForegroundColor Gray
        $network = Get-WinPulseNetworkMigrationSignals -profiles $profiles
        $checks += New-WinPulseCheckResult -id 'Migration.NetworkProfiles' -category 'Migration' -name 'Network profile detection' -status 'Info' -severity 'Low' -summary ('Found {0} Wi-Fi profiles and {1} VPN phonebooks.' -f $network.WiFiProfileCount, $network.VpnPhonebookCount) -recommendation 'Wi-Fi keys and VPN credentials are intentionally not exported.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'Network' -message $_.Exception.Message
        $network = [pscustomobject][ordered]@{ NetshAvailable = $false; WiFiProfilesExist = $false; WiFiProfileNames = @(); WiFiProfileCount = 0; VpnPhonebooks = @(); VpnPhonebookCount = 0; WiFiCredentialNote = 'Network collection failed.'; VpnCredentialNote = 'Network collection failed.' }
        $checks += New-WinPulseCheckResult -id 'Migration.NetworkProfiles' -category 'Migration' -name 'Network profile detection' -status 'Warning' -severity 'Low' -summary 'Network profile detection failed.' -recommendation 'Check Wi-Fi and VPN profiles manually.'
    }

    $applications = $null
    try {
        Write-Host '  Reading installed application inventory...' -ForegroundColor Gray
        $applications = Get-WinPulseMigrationApplicationInventory
        $checks += New-WinPulseCheckResult -id 'Migration.ApplicationInventory' -category 'Migration' -name 'Application inventory' -status 'Info' -severity 'Low' -summary ('Found {0} installed application entries. winget available: {1}.' -f $applications.Count, $applications.WingetAvailable) -recommendation 'Use inventory to plan reinstall list.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'Applications' -message $_.Exception.Message
        $applications = [pscustomobject][ordered]@{ Items = @(); Count = 0; WingetAvailable = $false; WingetPath = $null; WingetListRun = $false; WingetListNote = 'Application inventory failed.' }
        $checks += New-WinPulseCheckResult -id 'Migration.ApplicationInventory' -category 'Migration' -name 'Application inventory' -status 'Warning' -severity 'Medium' -summary 'Application inventory failed.' -recommendation 'Check installed applications manually.'
    }

    $developerHints = @()
    try {
        Write-Host '  Detecting developer/config hints...' -ForegroundColor Gray
        $developerHints = @(Get-WinPulseDeveloperHints -profiles $profiles)
        $hintCount = @($developerHints | Where-Object { $_.Exists }).Count
        $checks += New-WinPulseCheckResult -id 'Migration.DeveloperHints' -category 'Migration' -name 'Developer/config hints' -status 'Info' -severity 'Low' -summary ('Found {0} developer/config paths.' -f $hintCount) -recommendation 'Review sensitive developer data. Private keys are not exported by preflight.'
    }
    catch {
        $errors += New-WinPulsePreflightError -collector 'DeveloperHints' -message $_.Exception.Message
        $checks += New-WinPulseCheckResult -id 'Migration.DeveloperHints' -category 'Migration' -name 'Developer/config hints' -status 'Warning' -severity 'Low' -summary 'Developer/config hint detection failed.' -recommendation 'Check developer folders manually.'
    }

    $risk = New-WinPulseMigrationRiskSummary -profiles $profiles -oneDrive $oneDrive -email $email -browsers $browsers -network $network -applications $applications -windows11Readiness $readiness
    $migration = [ordered]@{
        Profiles       = @($profiles)
        OneDrive       = @($oneDrive)
        Email          = $email
        Browsers       = @($browsers)
        Network        = $network
        Applications   = $applications
        DeveloperHints = @($developerHints)
        RiskSummary    = $risk
    }

    $report = [pscustomobject][ordered]@{
        Tool               = [pscustomobject][ordered]@{
            Name          = 'WinPulse'
            Version       = $script:WinPulseVersion
            Mode          = 'MigrationPreflight'
            GeneratedAt   = (Get-Date).ToString('o')
            SchemaVersion = '0.1'
        }
        Computer           = $computer
        Windows11Readiness = $readiness
        Migration          = [pscustomobject]$migration
        Checks             = @($checks)
        Errors             = @($errors)
    }

    Write-Host '  Writing JSON, HTML, text, and log outputs...' -ForegroundColor Gray
    Export-WinPulseMigrationPreflightJson -report $report -path $jsonPath
    Export-WinPulseMigrationPreflightHtml -report $report -path $htmlPath
    Export-WinPulseMigrationPreflightText -report $report -path $textPath
    Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message 'Migration preflight completed.'

    Write-Host ''
    Write-Host 'Migration preflight complete.' -ForegroundColor Green
    Write-Host ('  Folder: {0}' -f $exportFolder) -ForegroundColor Green
    Write-Host ('  JSON:   {0}' -f $jsonPath) -ForegroundColor Gray
    Write-Host ('  HTML:   {0}' -f $htmlPath) -ForegroundColor Gray
    Write-Host ('  Text:   {0}' -f $textPath) -ForegroundColor Gray

    return [pscustomobject][ordered]@{
        ExportFolder = $exportFolder
        JsonPath      = $jsonPath
        HtmlPath      = $htmlPath
        TextPath      = $textPath
        LogPath       = $logPath
        Report        = $report
    }
}

# ===========================================================================
# Migration Backup Skeleton
#
# Explicit selection, dry-run planning, robocopy wrapper, and a manifest.
# Safe defaults: private keys and credential-like files are excluded, and the
# copy step requires explicit confirmation. Browser secrets, passwords, and
# DPAPI material are never exported.
# ===========================================================================

function Get-WinPulseBackupFolderCatalog {
    # Known per-user folders that are safe migration targets by default.
    # AppData is intentionally excluded because it is large, noisy, and can
    # hold credential-like data.
    [CmdletBinding()]
    param()

    return @(
        [ordered]@{ Key = 'Desktop';   Label = 'Desktop';   Relative = 'Desktop' },
        [ordered]@{ Key = 'Documents'; Label = 'Documents'; Relative = 'Documents' },
        [ordered]@{ Key = 'Downloads'; Label = 'Downloads'; Relative = 'Downloads' },
        [ordered]@{ Key = 'Pictures';  Label = 'Pictures';  Relative = 'Pictures' },
        [ordered]@{ Key = 'Videos';    Label = 'Videos';    Relative = 'Videos' },
        [ordered]@{ Key = 'Music';     Label = 'Music';     Relative = 'Music' },
        [ordered]@{ Key = 'Favorites'; Label = 'Favorites'; Relative = 'Favorites' }
    )
}

function Get-WinPulseBackupAppTargetDefinitions {
    [CmdletBinding()]
    param()

    return @(
        [ordered]@{
            Key            = 'chrome'
            Label          = 'Chrome data'
            Relative       = 'AppData\Local\Google'
            DetectRelative = 'AppData\Local\Google\Chrome\User Data'
            ExcludeFiles   = @()
        },
        [ordered]@{
            Key            = 'firefox'
            Label          = 'Firefox profile'
            Relative       = 'AppData\Roaming\Mozilla\Firefox'
            DetectRelative = 'AppData\Roaming\Mozilla\Firefox\Profiles'
            ExcludeFiles   = @()
        },
        [ordered]@{
            Key            = 'outlook'
            Label          = 'Outlook data (PST + autocomplete, no OST)'
            Relative       = 'AppData\Local\Microsoft\Outlook'
            DetectRelative = 'AppData\Local\Microsoft\Outlook'
            ExcludeFiles   = @('*.ost')
        }
    )
}

function Get-WinPulseBackupAppTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$profileRoot,

        [Parameter(Mandatory = $true)]
        [string]$userName
    )

    $targets = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($profileRoot) -or [string]::IsNullOrWhiteSpace($userName)) {
        return $targets.ToArray()
    }

    $profilePath = Join-WinPulsePath -path $profileRoot -childpath @($userName)
    foreach ($definition in (Get-WinPulseBackupAppTargetDefinitions)) {
        $detectPath = Join-Path -Path $profilePath -ChildPath $definition['DetectRelative']
        if (-not (Test-Path -LiteralPath $detectPath -PathType Container)) {
            continue
        }

        [void]$targets.Add([ordered]@{
            Key          = $definition['Key']
            Label        = $definition['Label']
            Relative     = $definition['Relative']
            ExcludeFiles = @($definition['ExcludeFiles'])
        })
    }

    return $targets.ToArray()
}

function ConvertTo-WinPulseBackupAppKeys {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$appKeys = @()
    )

    $known = @{}
    foreach ($definition in (Get-WinPulseBackupAppTargetDefinitions)) {
        $known[[string]$definition['Key']] = [string]$definition['Key']
    }

    $normalized = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($rawAppKey in @($appKeys)) {
        if ([string]::IsNullOrWhiteSpace($rawAppKey)) { continue }
        foreach ($appKey in ([string]$rawAppKey -split ',')) {
            if ([string]::IsNullOrWhiteSpace($appKey)) { continue }
            $key = $appKey.Trim().ToLowerInvariant()
            if (-not $known.ContainsKey($key)) {
                throw ('Unknown -BackupApps value "{0}". Valid values: {1}' -f $appKey, ((Get-WinPulseBackupAppTargetDefinitions | ForEach-Object { $_['Key'] }) -join ', '))
            }
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$normalized.Add($known[$key])
        }
    }

    return $normalized.ToArray()
}

function Get-WinPulseBackupExclusions {
    # Default safe exclusions. Standalone private keys (SSH/PuTTY) and the
    # registry hive files are not backed up by default. Certificate files
    # (.pfx/.p12/.pem/.cer/.crt) are intentionally INCLUDED because technicians
    # need them to migrate signing/VPN/email certificates. This list is
    # reported in the manifest so the scope is explicit and auditable.
    #
    # -includePrivateKeys is an explicit technician opt-in that widens scope to
    # back up SSH/PuTTY private keys and the .ssh/.gnupg folders. Registry hives
    # stay excluded regardless because they are locked and not doc-folder data.
    [CmdletBinding()]
    param(
        [switch]$includePrivateKeys
    )

    $keyFiles = @('*.ppk', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519')
    $hiveFiles = @('NTUSER.DAT', 'NTUSER.DAT.*', 'UsrClass.dat', 'UsrClass.dat.*')
    $keyDirs = @('.ssh', '.gnupg')
    # WindowsApps (under AppData\Local\Microsoft) holds App Execution Alias
    # reparse stubs for Store apps. They are 0-byte machine-specific links that
    # robocopy cannot copy (error 1920) and that are useless in a backup, so they
    # are always excluded. /XJ does not catch them (different reparse tag).
    $junkDirs = @('WindowsApps')

    if ($includePrivateKeys) {
        return [pscustomobject][ordered]@{
            Files = @($hiveFiles)
            Dirs  = @($junkDirs)
            Note  = 'Private keys INCLUDED by explicit technician opt-in. Registry hives and Store app alias stubs are still excluded.'
        }
    }

    return [pscustomobject][ordered]@{
        Files = @($keyFiles + $hiveFiles)
        Dirs  = @($keyDirs + $junkDirs)
        Note  = 'Standalone SSH/PuTTY private keys, registry hives, and Store app alias stubs (WindowsApps) are excluded. Certificate files are included so they can be migrated.'
    }
}

function Select-WinPulseBackupScopeOptIns {
    # Opt-in toggles for categories that are excluded by default. Everything
    # here is off unless the technician deliberately enables it. Returns an
    # array of selected category keys ('privatekeys', 'appdata').
    [CmdletBinding()]
    param()

    $items = @(
        @{ Label = 'Include private keys (.ssh, .gnupg, id_rsa, *.ppk)'; Key = 'privatekeys'; Hint = 'Sensitive' },
        @{ Label = 'Include AppData folder';                            Key = 'appdata';     Hint = 'Large/noisy' }
    )

    return @(Select-WinPulseMultiMenuItem -Title 'Include extras?  (optional, off by default)' -Items $items)
}

function Select-WinPulseBackupUsers {
    # Returns array of selected user names (profile folder names).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$profiles
    )

    if (@($profiles).Count -eq 0) {
        Write-Host '  No user profiles found to back up.' -ForegroundColor Yellow
        return @()
    }

    $items = @()
    foreach ($profile in @($profiles)) {
        $items += @{
            Label = ('{0}  ({1})' -f $profile.UserName, $profile.EstimatedTotalSize)
            Key   = $profile.UserName
            Hint  = $profile.ProfilePath
        }
    }

    return @(Select-WinPulseMultiMenuItem -Title 'Which users to back up?  (Space to tick, Enter to confirm)' -Items $items)
}

function Select-WinPulseBackupFolders {
    # Returns array of selected folder keys from the catalog.
    [CmdletBinding()]
    param()

    $items = @()
    foreach ($entry in (Get-WinPulseBackupFolderCatalog)) {
        $items += @{ Label = $entry['Label']; Key = $entry['Key']; Hint = $entry['Relative'] }
    }

    return @(Select-WinPulseMultiMenuItem -Title 'Which folders?  (AppData is excluded unless you opt in next)' -Items $items)
}

function Select-WinPulseBackupApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$profileRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$userKeys
    )

    $targetsByKey = [ordered]@{}
    foreach ($userKey in @($userKeys)) {
        foreach ($target in (Get-WinPulseBackupAppTargets -profileRoot $profileRoot -userName $userKey)) {
            $key = [string]$target['Key']
            if (-not $targetsByKey.Contains($key)) {
                $targetsByKey[$key] = $target
            }
        }
    }

    if ($targetsByKey.Count -eq 0) {
        return @()
    }

    $items = @()
    foreach ($key in @($targetsByKey.Keys)) {
        $target = $targetsByKey[$key]
        $items += @{ Label = $target['Label']; Key = $target['Key']; Hint = $target['Relative'] }
    }

    return @(Select-WinPulseMultiMenuItem -Title 'Detected application data (optional)' -Items $items)
}

function Measure-WinPulseBackupPlanItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path,

        [string[]]$extraExcludeFiles = @()
    )

    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return [pscustomobject][ordered]@{ Exists = $false; Bytes = [double]0; Size = '0 B' }
    }

    if (@($extraExcludeFiles).Count -eq 0) {
        return Get-WinPulsePathSize -path $path
    }

    $measure = Measure-WinPulseFolderFiltered -path $path -excludeFiles $extraExcludeFiles
    return [pscustomobject][ordered]@{
        Exists = $true
        Bytes  = [double]$measure.Bytes
        Size   = ConvertTo-ReadableSize -bytes ([double]$measure.Bytes)
    }
}

function New-WinPulseBackupPlan {
    # Builds a dry-run copy plan. Read-only: it only measures source folders
    # and computes destination paths. No files are copied here.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$profiles,

        [Parameter(Mandatory = $true)]
        [string[]]$userKeys,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$folderKeys,

        [Parameter(Mandatory = $true)]
        [string]$destinationRoot,

        [AllowEmptyCollection()]
        [string[]]$appKeys = @(),

        [string]$profileRoot = $null
    )

    $catalog = Get-WinPulseBackupFolderCatalog
    $selectedAppKeys = @(ConvertTo-WinPulseBackupAppKeys -appKeys $appKeys)
    $appKeySet = @{}
    foreach ($appKey in @($selectedAppKeys)) { $appKeySet[[string]$appKey] = $true }
    $items = @()
    $totalBytes = [double]0

    foreach ($userKey in @($userKeys)) {
        $profile = $profiles | Where-Object { $_.UserName -eq $userKey } | Select-Object -First 1
        if (-not $profile) { continue }

        foreach ($folderKey in @($folderKeys)) {
            $entry = $catalog | Where-Object { $_['Key'] -eq $folderKey } | Select-Object -First 1
            $relative = if ($entry) { $entry['Relative'] } else { $folderKey }

            $source = Join-Path -Path $profile.ProfilePath -ChildPath $relative
            $dest = Join-WinPulsePath -path $destinationRoot -childpath @($userKey, $relative)
            $size = Get-WinPulsePathSize -path $source

            $items += [pscustomobject][ordered]@{
                UserName          = $userKey
                Folder            = $folderKey
                Relative          = $relative
                ExtraExcludeFiles = @()
                Source            = $source
                Destination       = $dest
                Exists            = [bool]$size.Exists
                Bytes             = [double]$size.Bytes
                Size              = $size.Size
            }
            if ($size.Exists) { $totalBytes += [double]$size.Bytes }
        }

        if ($appKeySet.Count -gt 0) {
            $rootForApps = if ([string]::IsNullOrWhiteSpace($profileRoot)) { Split-Path -Path $profile.ProfilePath -Parent } else { $profileRoot }
            foreach ($target in (Get-WinPulseBackupAppTargets -profileRoot $rootForApps -userName $userKey)) {
                $appKey = [string]$target['Key']
                if (-not $appKeySet.ContainsKey($appKey)) { continue }

                $relative = [string]$target['Relative']
                $extraExcludeFiles = @($target['ExcludeFiles'])
                $source = Join-Path -Path $profile.ProfilePath -ChildPath $relative
                $dest = Join-WinPulsePath -path $destinationRoot -childpath @($userKey, $relative)
                $size = Measure-WinPulseBackupPlanItem -path $source -extraExcludeFiles $extraExcludeFiles

                $items += [pscustomobject][ordered]@{
                    UserName          = $userKey
                    Folder            = [string]$target['Label']
                    AppKey            = $appKey
                    Relative          = $relative
                    ExtraExcludeFiles = @($extraExcludeFiles)
                    Source            = $source
                    Destination       = $dest
                    Exists            = [bool]$size.Exists
                    Bytes             = [double]$size.Bytes
                    Size              = $size.Size
                }
                if ($size.Exists) { $totalBytes += [double]$size.Bytes }
            }
        }
    }

    return [pscustomobject][ordered]@{
        DestinationRoot = $destinationRoot
        Items           = @($items)
        ItemCount       = @($items).Count
        ExistingCount   = @($items | Where-Object { $_.Exists }).Count
        TotalBytes      = $totalBytes
        TotalSize       = ConvertTo-ReadableSize -bytes $totalBytes
    }
}

function Invoke-WinPulseRobocopy {
    # Thin robocopy wrapper. -DryRun adds /L so nothing is copied. The call
    # operator is used so source/destination paths with spaces are quoted
    # correctly. Robocopy writes its own per-item log via /LOG+.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$source,

        [Parameter(Mandatory = $true)]
        [string]$destination,

        [Parameter(Mandatory = $true)]
        [string]$logPath,

        [string[]]$excludeFiles = @(),

        [string[]]$excludeDirs = @(),

        [bool]$copyDirMetadata = $true,

        [switch]$DryRun
    )

    $robocopy = Get-Command -Name robocopy.exe -ErrorAction SilentlyContinue
    if (-not $robocopy) {
        return [pscustomobject][ordered]@{ ExitCode = -1; Success = $false; DryRun = [bool]$DryRun; LogPath = $logPath; Note = 'robocopy.exe not found.' }
    }

    # File data/attributes/timestamps are always copied. Directory metadata is
    # optional and requested via /DCOPY. Note: robocopy strips the destination
    # directory's existing attributes regardless of the /DCOPY flag, so when
    # copyDirMetadata is off (restore) we snapshot the target's attributes and
    # re-assert them after the copy. This protects the system/read-only markers
    # that make Desktop/Documents/Pictures known folders.
    $savedAttributes = $null
    if (-not $copyDirMetadata -and -not $DryRun -and (Test-Path -LiteralPath $destination)) {
        try { $savedAttributes = (Get-Item -LiteralPath $destination -Force).Attributes } catch { $savedAttributes = $null }
    }

    $arguments = @($source, $destination, '/E', '/COPY:DAT', '/R:1', '/W:1', '/XJ', '/NP', '/BYTES')
    if ($copyDirMetadata) { $arguments += '/DCOPY:DAT' } else { $arguments += '/DCOPY:T' }
    foreach ($f in @($excludeFiles)) { $arguments += '/XF'; $arguments += $f }
    foreach ($d in @($excludeDirs)) { $arguments += '/XD'; $arguments += $d }
    $arguments += ('/LOG+:{0}' -f $logPath)

    $note = ''
    try {
        if ($DryRun) {
            # Quiet preview: nothing is copied, the full plan goes to the log.
            $arguments += @('/L', '/NFL', '/NDL')
            & $robocopy.Source @arguments | Out-Null
            $code = $LASTEXITCODE
        }
        else {
            # Live feedback so a long copy is visibly not frozen: /TEE streams
            # robocopy's per-file output to us; we show the current file on a
            # single rewriting status line. Full detail still goes to the log.
            $arguments += @('/NDL', '/TEE')
            & $robocopy.Source @arguments | ForEach-Object {
                $line = ([string]$_).Trim()
                if ($line.Length -eq 0) { return }
                if ($line.Length -gt 76) { $line = '...' + $line.Substring($line.Length - 73) }
                Write-Host (("`r    {0}" -f $line).PadRight(84).Substring(0, 84)) -NoNewline -ForegroundColor Gray
            }
            $code = $LASTEXITCODE
            # Clear the status line so the next folder's message starts clean.
            Write-Host ("`r{0}`r" -f (' ' * 84)) -NoNewline
        }
    }
    catch {
        $code = -2
        $note = $_.Exception.Message
    }

    if ($null -ne $savedAttributes -and (Test-Path -LiteralPath $destination)) {
        try { (Get-Item -LiteralPath $destination -Force).Attributes = $savedAttributes } catch { }
    }

    # Robocopy exit codes 0-7 indicate success (copied / nothing to do / extra).
    # 8-15 mean some files could not be copied (commonly in-use/locked files on a
    # live profile, e.g. AppData) - a PARTIAL result, not a total failure. 16 is
    # a fatal error where nothing usable happened.
    $success = ($code -ge 0 -and $code -lt 8)
    $partial = ($code -ge 8 -and $code -lt 16)
    if ($partial -and [string]::IsNullOrEmpty($note)) {
        $note = 'Some files could not be copied (access-denied, reparse stubs, or in-use). The rest copied.'
    }

    return [pscustomobject][ordered]@{
        ExitCode = $code
        Success  = $success
        Partial  = $partial
        DryRun   = [bool]$DryRun
        LogPath  = $logPath
        Note     = $note
    }
}

function Get-WinPulseFilteredFiles {
    # Returns the files under a folder, skipping anything that matches the given
    # file name patterns or that lives under one of the excluded folder names.
    # Mirrors robocopy /XF and /XD semantics. Shared by the count and the
    # hash-sample verification so both see the same file set.
    [CmdletBinding()]
    param(
        [string]$path,
        [string[]]$excludeFiles = @(),
        [string[]]$excludeDirs = @()
    )

    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return $out.ToArray()
    }

    $exDirs = @(@($excludeDirs) | ForEach-Object { $_.ToLowerInvariant() })
    $rootLen = $path.TrimEnd('\').Length

    foreach ($file in (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        $skip = $false
        foreach ($pat in @($excludeFiles)) {
            if ($file.Name -like $pat) { $skip = $true; break }
        }
        if (-not $skip -and $exDirs.Count -gt 0) {
            $dir = $file.DirectoryName
            $relDir = if ($dir.Length -gt $rootLen) { $dir.Substring($rootLen) } else { '' }
            foreach ($seg in ($relDir -split '[\\/]' | Where-Object { $_ })) {
                if ($exDirs -contains $seg.ToLowerInvariant()) { $skip = $true; break }
            }
        }
        if ($skip) { continue }
        [void]$out.Add($file)
    }

    # .ToArray() instead of @($out): under StrictMode, @()-wrapping or piping a
    # Generic.List[object] throws "argument types do not match" in PS 5.1.
    return $out.ToArray()
}

function Measure-WinPulseFolderFiltered {
    # Counts files and bytes under a folder using the shared filtered file set.
    [CmdletBinding()]
    param(
        [string]$path,
        [string[]]$excludeFiles = @(),
        [string[]]$excludeDirs = @()
    )

    $files = Get-WinPulseFilteredFiles -path $path -excludeFiles $excludeFiles -excludeDirs $excludeDirs
    $bytes = [double]0
    foreach ($file in @($files)) {
        $bytes += [double]$file.Length
    }

    return [pscustomobject][ordered]@{ Files = @($files).Count; Bytes = $bytes }
}

function Get-WinPulseCopyVerification {
    # Compares an expected source set (with the copy's exclusions applied)
    # against what landed at the destination. The destination may legitimately
    # hold extra pre-existing files, so verification only fails when the
    # destination is missing files or bytes the copy should have produced.
    #
    # -hashSampleSize > 0 adds an optional, stronger check: a random sample of
    # source files is SHA256-hashed and compared against the matching
    # destination file. Any mismatch or missing destination file fails it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$source,

        [Parameter(Mandatory = $true)]
        [string]$destination,

        [string[]]$excludeFiles = @(),

        [string[]]$excludeDirs = @(),

        [int]$hashSampleSize = 0
    )

    $src = Measure-WinPulseFolderFiltered -path $source -excludeFiles $excludeFiles -excludeDirs $excludeDirs
    $dst = Measure-WinPulseFolderFiltered -path $destination

    $status = 'Verified'
    $note = ''
    if ($dst.Files -lt $src.Files -or $dst.Bytes -lt $src.Bytes) {
        $status = 'Mismatch'
        $note = ('Expected at least {0} files / {1} bytes, found {2} files / {3} bytes.' -f $src.Files, $src.Bytes, $dst.Files, $dst.Bytes)
    }

    $hashSampled = 0
    $hashMatched = 0
    $hashMismatched = 0
    if ($hashSampleSize -gt 0 -and $src.Files -gt 0) {
        $files = Get-WinPulseFilteredFiles -path $source -excludeFiles $excludeFiles -excludeDirs $excludeDirs
        $srcRoot = $source.TrimEnd('\')
        $sample = if (@($files).Count -le $hashSampleSize) { @($files) } else { @($files | Get-Random -Count $hashSampleSize) }
        foreach ($file in $sample) {
            $hashSampled++
            $relative = $file.FullName.Substring($srcRoot.Length).TrimStart('\')
            $destFile = Join-Path -Path $destination -ChildPath $relative
            if (-not (Test-Path -LiteralPath $destFile)) { $hashMismatched++; continue }
            try {
                $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $destHash = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($sourceHash -eq $destHash) { $hashMatched++ } else { $hashMismatched++ }
            }
            catch {
                $hashMismatched++
            }
        }
        if ($hashMismatched -gt 0) {
            $status = 'Mismatch'
            $hashNote = ('{0} of {1} sampled file hashes did not match.' -f $hashMismatched, $hashSampled)
            $note = if ($note) { '{0} {1}' -f $note, $hashNote } else { $hashNote }
        }
    }

    return [pscustomobject][ordered]@{
        SourceFiles    = $src.Files
        SourceBytes    = $src.Bytes
        DestFiles      = $dst.Files
        DestBytes      = $dst.Bytes
        HashSampled    = $hashSampled
        HashMatched    = $hashMatched
        HashMismatched = $hashMismatched
        Status         = $status
        Note           = $note
    }
}

function ConvertTo-WinPulseCopyReportRows {
    # Flattens a backup or restore manifest's Items (plus their verification)
    # into a uniform set of rows for the text and HTML reports.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$manifest
    )

    $isDryRun = ($manifest.Tool.Action -eq 'DryRun')
    $rows = @()
    foreach ($item in @($manifest.Items)) {
        $dest = ''
        if ($item.PSObject.Properties['Destination']) { $dest = [string]$item.Destination }
        elseif ($item.PSObject.Properties['Target']) { $dest = [string]$item.Target }

        $isPartial = ($item.PSObject.Properties['Partial'] -and $item.Partial)
        $result = if ($item.Skipped) { 'Skipped' } elseif ($isDryRun) { 'Planned' } elseif ($item.Success) { 'OK' } elseif ($isPartial) { 'PARTIAL' } else { 'FAILED' }

        $verify = '-'
        $srcFiles = ''
        $destFiles = ''
        $hash = '-'
        if ($item.PSObject.Properties['Verification'] -and $item.Verification) {
            $verify = [string]$item.Verification.Status
            $srcFiles = $item.Verification.SourceFiles
            $destFiles = $item.Verification.DestFiles
            if ($item.Verification.PSObject.Properties['HashSampled'] -and [int]$item.Verification.HashSampled -gt 0) {
                $hash = ('{0}/{1}' -f $item.Verification.HashMatched, $item.Verification.HashSampled)
            }
        }

        $rows += [pscustomobject][ordered]@{
            User        = [string]$item.UserName
            Folder      = [string]$item.Folder
            Result      = $result
            Verify      = $verify
            SrcFiles    = $srcFiles
            DestFiles   = $destFiles
            Hash        = $hash
            Exit        = $item.ExitCode
            Destination = $dest
            Note        = [string]$item.Note
        }
    }

    return @($rows)
}

function Export-WinPulseMigrationCopyReportText {
    # Human-readable text summary for a backup or restore run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$manifest,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $isBackup = ($manifest.Tool.Mode -eq 'MigrationBackup')
    $title = if ($isBackup) { 'WinPulse Migration Backup Report' } else { 'WinPulse Migration Restore Report' }
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add($title)
    $lines.Add(('Generated: {0}' -f $manifest.Tool.GeneratedAt))
    $lines.Add(('Action: {0} | WinPulse {1}' -f $manifest.Tool.Action, $manifest.Tool.Version))
    $lines.Add(('Machine: {0}' -f $manifest.Computer))
    $lines.Add('')
    if ($isBackup) {
        $lines.Add(('Destination: {0}' -f $manifest.DestinationRoot))
        $lines.Add(('Users: {0}' -f (@($manifest.Users) -join ', ')))
        $lines.Add(('Folders: {0}' -f (@($manifest.Folders) -join ', ')))
        if ($manifest.PSObject.Properties['Apps'] -and @($manifest.Apps).Count -gt 0) {
            $lines.Add(('Apps: {0}' -f (@($manifest.Apps) -join ', ')))
        }
    }
    else {
        $lines.Add(('Backup source: {0}' -f $manifest.BackupRoot))
        $lines.Add(('Restore root: {0}' -f $manifest.RestoreRoot))
        if ($manifest.PSObject.Properties['RestoreAsUser'] -and -not [string]::IsNullOrWhiteSpace([string]$manifest.RestoreAsUser)) {
            $lines.Add(('Restore as user: {0}' -f $manifest.RestoreAsUser))
        }
    }
    $lines.Add('')
    $lines.Add(('Plan: {0} items, {1} with data, total {2}' -f $manifest.Plan.ItemCount, $manifest.Plan.ExistingCount, $manifest.Plan.TotalSize))
    $partialCount = if ($manifest.PSObject.Properties['PartialCount']) { [int]$manifest.PartialCount } else { 0 }
    $lines.Add(('Failed: {0} | Partial: {1} | Verification mismatches: {2}' -f $manifest.FailedCount, $partialCount, $manifest.MismatchCount))
    $lines.Add('')
    $lines.Add('Items:')
    foreach ($row in (ConvertTo-WinPulseCopyReportRows -manifest $manifest)) {
        $verifyText = if ($row.Verify -eq '-') { '' } else { (' | verify={0} ({1}->{2} files)' -f $row.Verify, $row.SrcFiles, $row.DestFiles) }
        $hashText = if ($row.Hash -eq '-') { '' } else { (' | hash {0} matched' -f $row.Hash) }
        $lines.Add(('- {0}\{1}: {2} (exit {3}){4}{5}' -f $row.User, $row.Folder, $row.Result, $row.Exit, $verifyText, $hashText))
    }
    if (@($manifest.Items).Count -eq 0) {
        $lines.Add('- No items.')
    }
    $lines.Add('')
    if ($manifest.PSObject.Properties['Exclusions'] -and $manifest.Exclusions) {
        $lines.Add(('Excluded files: {0}' -f (@($manifest.Exclusions.Files) -join ', ')))
        if (@($manifest.Exclusions.Dirs).Count -gt 0) {
            $lines.Add(('Excluded dirs: {0}' -f (@($manifest.Exclusions.Dirs) -join ', ')))
        }
        $lines.Add('')
    }
    $lines.Add('Notes:')
    foreach ($note in @($manifest.SafetyNotes)) {
        $lines.Add(('- {0}' -f $note))
    }
    $jsonName = if ($isBackup) { 'manifest.json' } else { 'migration-restore.json' }
    $lines.Add(('- See {0} for full machine-readable details.' -f $jsonName))

    $lines | Set-Content -Path $path -Encoding UTF8
}

function Export-WinPulseMigrationCopyReportHtml {
    # Printable HTML summary for a backup or restore run, matching the preflight
    # report styling.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$manifest,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $isBackup = ($manifest.Tool.Mode -eq 'MigrationBackup')
    $title = if ($isBackup) { 'WinPulse Migration Backup' } else { 'WinPulse Migration Restore' }
    $rows = ConvertTo-WinPulseCopyReportRows -manifest $manifest

    $partialCount = if ($manifest.PSObject.Properties['PartialCount']) { [int]$manifest.PartialCount } else { 0 }
    $statusClass = if ([int]$manifest.FailedCount -gt 0) { 'notready' }
        elseif ([int]$manifest.MismatchCount -gt 0 -or $partialCount -gt 0) { 'attention' }
        elseif ($manifest.Tool.Action -eq 'DryRun') { 'unknown' }
        else { 'ready' }
    $statusText = if ([int]$manifest.FailedCount -gt 0) { ('{0} failed' -f $manifest.FailedCount) }
        elseif ([int]$manifest.MismatchCount -gt 0) { ('{0} mismatch' -f $manifest.MismatchCount) }
        elseif ($partialCount -gt 0) { ('{0} partial' -f $partialCount) }
        elseif ($manifest.Tool.Action -eq 'DryRun') { 'Dry run' }
        else { 'All verified' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WinPulse Migration Report</title>
<style>
:root{--bg:#111827;--panel:#182233;--panel2:#101826;--border:#334155;--text:#e5e7eb;--muted:#94a3b8;--ok:#22c55e;--warn:#f59e0b;--crit:#ef4444;--info:#38bdf8}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Tahoma,sans-serif;line-height:1.45}
.container{max-width:1180px;margin:0 auto;padding:24px}
header{border-bottom:2px solid var(--border);padding-bottom:18px;margin-bottom:18px}
h1{font-size:1.8rem;margin:0 0 6px;color:var(--info)}
h2{font-size:1.05rem;margin:0 0 10px;color:var(--info)}
section{background:var(--panel);border:1px solid var(--border);border-radius:6px;padding:16px;margin:0 0 14px}
.subtitle,.empty,footer{color:var(--muted)}
.badge{display:inline-block;border:1px solid var(--border);border-radius:4px;padding:4px 9px;margin:4px 8px 4px 0;font-weight:600}
.ready{color:var(--ok);border-color:var(--ok)}.attention{color:var(--warn);border-color:var(--warn)}.notready{color:var(--crit);border-color:var(--crit)}.unknown{color:var(--muted)}
.kv{display:grid;grid-template-columns:minmax(180px,260px) 1fr;gap:5px 18px}
.k{color:var(--muted);font-weight:600}.v{color:var(--text)}
table{width:100%;border-collapse:collapse;font-size:.86rem}
th{background:var(--panel2);color:var(--muted);text-align:left;padding:7px;border-bottom:1px solid var(--border)}
td{padding:7px;border-bottom:1px solid rgba(148,163,184,.16);vertical-align:top}
tr:hover td{background:rgba(255,255,255,.025)}
ul{margin:0;padding-left:20px}
code{color:var(--info)}
footer{font-size:.8rem;border-top:1px solid var(--border);padding-top:16px;margin-top:18px}
@media print{body{background:#fff;color:#111}.container{max-width:none;padding:10px}section{background:#fff;border-color:#ccc;break-inside:avoid}.subtitle,.empty,footer,.k,th{color:#555}th{background:#eee}.v,td{color:#111}}
</style>
</head>
<body>
<div class="container">
'@)

    [void]$sb.Append(('<header><h1>{0}</h1><div class="subtitle">{1} | {2} | WinPulse {3}</div>' -f
            (ConvertTo-WinPulseHtmlText -value $title),
            (ConvertTo-WinPulseHtmlText -value $manifest.Computer),
            (ConvertTo-WinPulseHtmlText -value $manifest.Tool.GeneratedAt),
            (ConvertTo-WinPulseHtmlText -value $manifest.Tool.Version)))
    [void]$sb.Append(('<div class="badge">Action: {0}</div>' -f (ConvertTo-WinPulseHtmlText -value $manifest.Tool.Action)))
    [void]$sb.Append(('<div class="badge {0}">{1}</div></header>' -f $statusClass, (ConvertTo-WinPulseHtmlText -value $statusText)))

    [void]$sb.Append('<section><h2>Summary</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Machine' -value $manifest.Computer
    if ($isBackup) {
        Add-WinPulseMigrationHtmlKv -builder $sb -key 'Destination' -value $manifest.DestinationRoot
        Add-WinPulseMigrationHtmlKv -builder $sb -key 'Users' -value (@($manifest.Users) -join ', ')
        Add-WinPulseMigrationHtmlKv -builder $sb -key 'Folders' -value (@($manifest.Folders) -join ', ')
        if ($manifest.PSObject.Properties['Apps'] -and @($manifest.Apps).Count -gt 0) {
            Add-WinPulseMigrationHtmlKv -builder $sb -key 'Apps' -value (@($manifest.Apps) -join ', ')
        }
    }
    else {
        Add-WinPulseMigrationHtmlKv -builder $sb -key 'Backup source' -value $manifest.BackupRoot
        Add-WinPulseMigrationHtmlKv -builder $sb -key 'Restore root' -value $manifest.RestoreRoot
        if ($manifest.PSObject.Properties['RestoreAsUser'] -and -not [string]::IsNullOrWhiteSpace([string]$manifest.RestoreAsUser)) {
            Add-WinPulseMigrationHtmlKv -builder $sb -key 'Restore as user' -value $manifest.RestoreAsUser
        }
    }
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Items (with data)' -value ('{0} ({1})' -f $manifest.Plan.ItemCount, $manifest.Plan.ExistingCount)
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Total size' -value $manifest.Plan.TotalSize
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Failed' -value $manifest.FailedCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Partial (in-use skipped)' -value $partialCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Verification mismatches' -value $manifest.MismatchCount
    [void]$sb.Append('</div></section>')

    [void]$sb.Append('<section><h2>Items</h2>')
    [void]$sb.Append((ConvertTo-WinPulseMigrationHtmlTable -data $rows -columns @('User', 'Folder', 'Result', 'Verify', 'SrcFiles', 'DestFiles', 'Hash', 'Exit', 'Destination', 'Note')))
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Safety Notes</h2><ul>')
    foreach ($note in @($manifest.SafetyNotes)) {
        [void]$sb.Append(('<li>{0}</li>' -f (ConvertTo-WinPulseHtmlText -value $note)))
    }
    [void]$sb.Append('</ul></section>')

    [void]$sb.Append(('<footer>Generated by WinPulse {0}</footer>' -f (ConvertTo-WinPulseHtmlText -value $manifest.Tool.Version)))
    [void]$sb.Append('</div></body></html>')

    $sb.ToString() | Set-Content -Path $path -Encoding UTF8
}

function Get-WinPulseMigrationReportCss {
    [CmdletBinding()]
    param()

    return @'
:root{--bg:#111827;--panel:#182233;--panel2:#101826;--border:#334155;--text:#e5e7eb;--muted:#94a3b8;--ok:#22c55e;--warn:#f59e0b;--crit:#ef4444;--info:#38bdf8}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Tahoma,sans-serif;line-height:1.45}
.container{max-width:1180px;margin:0 auto;padding:24px}
header{border-bottom:2px solid var(--border);padding-bottom:18px;margin-bottom:18px}
h1{font-size:1.8rem;margin:0 0 6px;color:var(--info)}
h2{font-size:1.05rem;margin:0 0 10px;color:var(--info)}
section{background:var(--panel);border:1px solid var(--border);border-radius:6px;padding:16px;margin:0 0 14px}
.subtitle,.empty,footer{color:var(--muted)}
.badge{display:inline-block;border:1px solid var(--border);border-radius:4px;padding:4px 9px;margin:4px 8px 4px 0;font-weight:600}
.ready{color:var(--ok);border-color:var(--ok)}.attention{color:var(--warn);border-color:var(--warn)}.notready{color:var(--crit);border-color:var(--crit)}.unknown{color:var(--muted)}
.kv{display:grid;grid-template-columns:minmax(180px,260px) 1fr;gap:5px 18px}
.k{color:var(--muted);font-weight:600}.v{color:var(--text)}
table{width:100%;border-collapse:collapse;font-size:.86rem}
th{background:var(--panel2);color:var(--muted);text-align:left;padding:7px;border-bottom:1px solid var(--border)}
td{padding:7px;border-bottom:1px solid rgba(148,163,184,.16);vertical-align:top}
tr:hover td{background:rgba(255,255,255,.025)}
ul{margin:0;padding-left:20px}
code{color:var(--info)}
footer{font-size:.8rem;border-top:1px solid var(--border);padding-top:16px;margin-top:18px}
@media print{body{background:#fff;color:#111}.container{max-width:none;padding:10px}section{background:#fff;border-color:#ccc;break-inside:avoid}.subtitle,.empty,footer,.k,th{color:#555}th{background:#eee}.v,td{color:#111}}
'@
}

function Export-WinPulseMigrationVerifyReportText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$record,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('WinPulse Migration Verify Report')
    $lines.Add(('Generated: {0}' -f $record.Tool.GeneratedAt))
    $lines.Add(('Action: {0} | WinPulse {1}' -f $record.Tool.Action, $record.Tool.Version))
    $lines.Add(('Machine: {0}' -f $record.Computer))
    $lines.Add(('Backup root: {0}' -f $record.BackupRoot))
    $lines.Add('')
    $lines.Add(('Summary: Intact {0} | Drift {1} | Skipped {2}' -f $record.IntactCount, $record.DriftCount, $record.SkippedCount))
    $lines.Add('')
    $lines.Add('Items:')
    foreach ($item in @($record.Items)) {
        $lines.Add(('- {0}\{1}: {2} | recorded {3} files / {4} bytes | current {5} files / {6} bytes | {7}' -f
                $item.UserName,
                $item.Folder,
                $item.Status,
                $item.RecordedFiles,
                $item.RecordedBytes,
                $item.CurrentFiles,
                $item.CurrentBytes,
                $item.Note))
    }
    if (@($record.Items).Count -eq 0) {
        $lines.Add('- No items.')
    }
    $lines.Add('')
    $lines.Add('Notes:')
    foreach ($note in @($record.SafetyNotes)) {
        $lines.Add(('- {0}' -f $note))
    }
    $lines.Add('- See migration-verify.json for full machine-readable details.')

    $lines | Set-Content -Path $path -Encoding UTF8
}

function Export-WinPulseMigrationVerifyReportHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$record,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $rows = @()
    foreach ($item in @($record.Items)) {
        $status = [string]$item.Status
        $displayStatus = if ($status -eq 'Drift') { 'DRIFT - ATTENTION' } else { $status }
        $rows += [pscustomobject][ordered]@{
            User          = $item.UserName
            Folder        = $item.Folder
            Status        = $displayStatus
            RecordedFiles = $item.RecordedFiles
            RecordedBytes = $item.RecordedBytes
            CurrentFiles  = $item.CurrentFiles
            CurrentBytes  = $item.CurrentBytes
            Note          = $item.Note
        }
    }

    $statusClass = if ([int]$record.DriftCount -gt 0) { 'attention' } else { 'ready' }
    $statusText = if ([int]$record.DriftCount -gt 0) { ('{0} drift item(s)' -f $record.DriftCount) } else { 'Backup intact' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(('<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>WinPulse Migration Verify Report</title><style>{0}</style></head><body><div class="container">' -f (Get-WinPulseMigrationReportCss)))
    [void]$sb.Append(('<header><h1>WinPulse Migration Verify</h1><div class="subtitle">{0} | {1} | WinPulse {2}</div>' -f
            (ConvertTo-WinPulseHtmlText -value $record.Computer),
            (ConvertTo-WinPulseHtmlText -value $record.Tool.GeneratedAt),
            (ConvertTo-WinPulseHtmlText -value $record.Tool.Version)))
    [void]$sb.Append(('<div class="badge">Action: {0}</div>' -f (ConvertTo-WinPulseHtmlText -value $record.Tool.Action)))
    [void]$sb.Append(('<div class="badge {0}">{1}</div></header>' -f $statusClass, (ConvertTo-WinPulseHtmlText -value $statusText)))

    [void]$sb.Append('<section><h2>Summary</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Machine' -value $record.Computer
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Backup root' -value $record.BackupRoot
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Intact' -value $record.IntactCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Drift' -value $record.DriftCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Skipped' -value $record.SkippedCount
    [void]$sb.Append('</div></section>')

    [void]$sb.Append('<section><h2>Items</h2>')
    $itemTableHtml = ConvertTo-WinPulseMigrationHtmlTable -data $rows -columns @('User', 'Folder', 'Status', 'RecordedFiles', 'RecordedBytes', 'CurrentFiles', 'CurrentBytes', 'Note')
    $itemTableHtml = $itemTableHtml -replace '<td>DRIFT - ATTENTION</td>', '<td><span class="badge attention">DRIFT - ATTENTION</span></td>'
    [void]$sb.Append($itemTableHtml)
    [void]$sb.Append('</section>')

    [void]$sb.Append('<section><h2>Safety Notes</h2><ul>')
    foreach ($note in @($record.SafetyNotes)) {
        [void]$sb.Append(('<li>{0}</li>' -f (ConvertTo-WinPulseHtmlText -value $note)))
    }
    [void]$sb.Append('</ul></section>')
    [void]$sb.Append(('<footer>Generated by WinPulse {0}</footer></div></body></html>' -f (ConvertTo-WinPulseHtmlText -value $record.Tool.Version)))

    $sb.ToString() | Set-Content -Path $path -Encoding UTF8
}

function Export-WinPulseMigrationAppsReportText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$record,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('WinPulse Migration Apps Report')
    $lines.Add(('Generated: {0}' -f $record.Tool.GeneratedAt))
    $lines.Add(('Action: {0} | WinPulse {1}' -f $record.Tool.Action, $record.Tool.Version))
    $lines.Add(('Machine: {0}' -f $record.Computer))
    $lines.Add(('Backup root: {0}' -f $record.BackupRoot))
    $lines.Add('')
    $lines.Add(('Summary: Selected {0} | Installed {1} | AlreadyInstalled {2} | Failed {3} | DryRun {4}' -f $record.SelectedCount, $record.InstalledCount, $record.AlreadyInstalledCount, $record.FailedCount, $record.DryRunCount))
    if ($record.Tool.Action -eq 'DryRun') {
        $lines.Add('Dry-run note: Nothing was installed; commands below were not executed.')
    }
    $lines.Add('')
    $lines.Add('Packages:')
    foreach ($item in @($record.Items)) {
        $result = if ($item.DryRun) { 'DRY-RUN' } elseif ($item.Success) { 'OK' } else { 'FAILED' }
        $status = if ($item.PSObject.Properties['Status']) { [string]$item.Status } else { $result }
        $exitText = if ($null -eq $item.ExitCode) { '-' } else { [string]$item.ExitCode }
        $lines.Add(('- {0}: {1} | Status {2} | exit {3} | {4}' -f $item.PackageId, $result, $status, $exitText, $item.Command))
    }
    if (@($record.Items).Count -eq 0) {
        $lines.Add('- No packages.')
    }
    $lines.Add('')
    $lines.Add('- See migration-apps.json for full machine-readable details.')

    $lines | Set-Content -Path $path -Encoding UTF8
}

function Export-WinPulseMigrationAppsReportHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$record,

        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $rows = @()
    foreach ($item in @($record.Items)) {
        $result = if ($item.DryRun) { 'DRY-RUN' } elseif ($item.Success) { 'OK' } else { 'FAILED' }
        $status = if ($item.PSObject.Properties['Status']) { [string]$item.Status } else { $result }
        $exitText = if ($null -eq $item.ExitCode) { '-' } else { [string]$item.ExitCode }
        $rows += [pscustomobject][ordered]@{
            PackageId = $item.PackageId
            Status    = $status
            Result    = $result
            ExitCode  = $exitText
            Command   = $item.Command
        }
    }

    $statusClass = if ([int]$record.FailedCount -gt 0) { 'attention' } elseif ($record.Tool.Action -eq 'DryRun') { 'unknown' } else { 'ready' }
    $statusText = if ([int]$record.FailedCount -gt 0) { ('{0} failed' -f $record.FailedCount) } elseif ($record.Tool.Action -eq 'DryRun') { 'Dry run - nothing installed' } else { 'Install complete' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(('<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>WinPulse Migration Apps Report</title><style>{0}</style></head><body><div class="container">' -f (Get-WinPulseMigrationReportCss)))
    [void]$sb.Append(('<header><h1>WinPulse Migration Apps</h1><div class="subtitle">{0} | {1} | WinPulse {2}</div>' -f
            (ConvertTo-WinPulseHtmlText -value $record.Computer),
            (ConvertTo-WinPulseHtmlText -value $record.Tool.GeneratedAt),
            (ConvertTo-WinPulseHtmlText -value $record.Tool.Version)))
    [void]$sb.Append(('<div class="badge">Action: {0}</div>' -f (ConvertTo-WinPulseHtmlText -value $record.Tool.Action)))
    [void]$sb.Append(('<div class="badge {0}">{1}</div></header>' -f $statusClass, (ConvertTo-WinPulseHtmlText -value $statusText)))

    [void]$sb.Append('<section><h2>Summary</h2><div class="kv">')
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Machine' -value $record.Computer
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Backup root' -value $record.BackupRoot
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Selected' -value $record.SelectedCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Installed' -value $record.InstalledCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'AlreadyInstalled' -value $record.AlreadyInstalledCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'Failed' -value $record.FailedCount
    Add-WinPulseMigrationHtmlKv -builder $sb -key 'DryRun' -value $record.DryRunCount
    if ($record.Tool.Action -eq 'DryRun') {
        Add-WinPulseMigrationHtmlKv -builder $sb -key 'Dry-run note' -value 'Nothing was installed; commands below were not executed.'
    }
    [void]$sb.Append('</div></section>')

    [void]$sb.Append('<section><h2>Packages</h2>')
    $packageTableHtml = ConvertTo-WinPulseMigrationHtmlTable -data $rows -columns @('PackageId', 'Status', 'Result', 'ExitCode', 'Command')
    $packageTableHtml = $packageTableHtml -replace '<td>Installed</td>', '<td><span class="badge ready">Installed</span></td>'
    $packageTableHtml = $packageTableHtml -replace '<td>AlreadyInstalled</td>', '<td><span class="badge attention">AlreadyInstalled</span></td>'
    $packageTableHtml = $packageTableHtml -replace '<td>Failed</td>', '<td><span class="badge notready">Failed</span></td>'
    $packageTableHtml = $packageTableHtml -replace '<td>DryRun</td>', '<td><span class="badge unknown">DryRun</span></td>'
    [void]$sb.Append($packageTableHtml)
    [void]$sb.Append('</section>')
    [void]$sb.Append(('<footer>Generated by WinPulse {0}</footer></div></body></html>' -f (ConvertTo-WinPulseHtmlText -value $record.Tool.Version)))

    $sb.ToString() | Set-Content -Path $path -Encoding UTF8
}

function Invoke-WinPulseMigrationBackup {
    # Orchestrates the backup skeleton: select users, select folders, choose a
    # destination, build a dry-run plan, then optionally execute the copy and
    # write a manifest. Read-only until the technician explicitly confirms.
    [CmdletBinding()]
    param(
        [string[]]$BackupUsers = @(),
        [string[]]$BackupFolders = @(),
        [string[]]$BackupApps = @(),
        [string]$BackupDestination = $null,
        [switch]$BackupExecute,
        [switch]$BackupIncludePrivateKeys,
        [switch]$BackupIncludeAppData,
        [switch]$BackupHashSample,
        [switch]$SkipBackupAppList,
        [string]$BackupProfilesRoot = $null
    )

    $hasBackupParameters = (
        @($BackupUsers).Count -gt 0 -or
        @($BackupFolders).Count -gt 0 -or
        @($BackupApps).Count -gt 0 -or
        -not [string]::IsNullOrWhiteSpace($BackupDestination) -or
        -not [string]::IsNullOrWhiteSpace($BackupProfilesRoot) -or
        $BackupExecute -or
        $BackupIncludePrivateKeys -or
        $BackupIncludeAppData -or
        $BackupHashSample -or
        $SkipBackupAppList
    )
    $nonInteractive = (
        @($BackupUsers).Count -gt 0 -and
        (@($BackupFolders).Count -gt 0 -or @($BackupApps).Count -gt 0) -and
        -not [string]::IsNullOrWhiteSpace($BackupDestination)
    )
    if ($hasBackupParameters -and -not $nonInteractive) {
        throw 'Non-interactive MigrationBackup requires -BackupUsers, -BackupDestination, and -BackupFolders or -BackupApps.'
    }

    Clear-Host
    Write-WinPulseHeader -title 'Migration Backup'
    Write-Host '  Copy a user''s files to a backup folder you choose (local or external drive).' -ForegroundColor Cyan
    Write-Host '  You pick the users and folders. Preview first; nothing is copied until you type YES.' -ForegroundColor Cyan
    Write-Host '  Certificates are kept; passwords and private keys are skipped unless you opt in.' -ForegroundColor Cyan
    Write-Host ''

    Write-Host '  Scanning user profiles...' -ForegroundColor Gray
    $profileRoot = if ([string]::IsNullOrWhiteSpace($BackupProfilesRoot)) { 'C:\Users' } else { $BackupProfilesRoot }
    $profiles = @(Get-WinPulseMigrationProfiles -root $profileRoot)
    if ($profiles.Count -eq 0) {
        Write-Host '  No user profiles found. Nothing to back up.' -ForegroundColor Yellow
        return $null
    }

    $userKeys = @(if ($nonInteractive) { @($BackupUsers) } else { @(Select-WinPulseBackupUsers -profiles $profiles) })
    if ($userKeys.Count -eq 0) {
        Write-Host '  No users selected. Backup cancelled.' -ForegroundColor Yellow
        return $null
    }

    $folderKeys = @(if ($nonInteractive) { @($BackupFolders) } else { @(Select-WinPulseBackupFolders) })
    $appKeys = @(if ($nonInteractive) { @(ConvertTo-WinPulseBackupAppKeys -appKeys $BackupApps) } else { @(Select-WinPulseBackupApps -profileRoot $profileRoot -userKeys $userKeys) })
    if ($folderKeys.Count -eq 0 -and $appKeys.Count -eq 0) {
        Write-Host '  No folders or application data selected. Backup cancelled.' -ForegroundColor Yellow
        return $null
    }

    $optIns = @()
    if ($nonInteractive) {
        if ($BackupIncludePrivateKeys) { $optIns += 'privatekeys' }
        if ($BackupIncludeAppData) { $optIns += 'appdata' }
    }
    else {
        $optIns = @(Select-WinPulseBackupScopeOptIns)
    }
    $includeKeys = ($optIns -contains 'privatekeys')
    $includeAppData = ($optIns -contains 'appdata')
    if ($includeKeys -or $includeAppData) {
        Write-Host ''
        if ($includeKeys) {
            Write-Host '  WARNING: private keys (.ssh, .gnupg, id_rsa, *.ppk) will be backed up.' -ForegroundColor Yellow
        }
        if ($includeAppData) {
            Write-Host '  WARNING: AppData will be backed up (large, noisy, may hold credential-like data).' -ForegroundColor Yellow
        }
    }
    if ($includeAppData -and ($folderKeys -notcontains 'AppData')) {
        $folderKeys += 'AppData'
    }

    if ($nonInteractive) {
        $captureAppList = -not $SkipBackupAppList
    }
    else {
        $captureChoice = Select-WinPulseMenuItem -Title 'Capture the installed software list (for later winget reinstall)?' -Items @(
            @{ Label = 'Yes'; Key = 'Y'; Hint = 'Recommended; default' },
            @{ Label = 'No';  Key = 'N'; Hint = 'Skip app list capture' }
        )
        $captureAppList = ($captureChoice -ne 'N')
    }

    $computerName = Get-WinPulseSafeComputerName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # Default to a persistent top-level folder, NOT under C:\ProgramData\WinPulse
    # (which exit cleanup wipes). A real backup must survive the exit cleanup.
    $defaultRoot = Join-Path -Path 'C:\WinPulseBackups' -ChildPath ('MigrationBackup-{0}-{1}' -f $computerName, $stamp)

    Clear-Host
    Write-WinPulseHeader -title 'Migration Backup'
    Write-Host ('  Default destination: {0}' -f $defaultRoot) -ForegroundColor Gray
    if ($nonInteractive) {
        $destinationRoot = $BackupDestination.Trim()
    }
    else {
        $destPicked = Select-WinPulseFolderPath -Title 'Backup destination'
        $destinationRoot = if ([string]::IsNullOrWhiteSpace($destPicked)) { $defaultRoot } else { $destPicked }
    }

    Write-Host ''
    Write-Host '  Building dry-run copy plan...' -ForegroundColor Gray
    $exclusions = Get-WinPulseBackupExclusions -includePrivateKeys:$includeKeys
    $plan = New-WinPulseBackupPlan -profiles $profiles -userKeys $userKeys -folderKeys $folderKeys -destinationRoot $destinationRoot -appKeys $appKeys -profileRoot $profileRoot

    Write-Host ''
    Write-Host ('  Plan: {0} items, {1} exist, total {2}' -f $plan.ItemCount, $plan.ExistingCount, $plan.TotalSize) -ForegroundColor Cyan
    Write-Host ('  Destination: {0}' -f $destinationRoot) -ForegroundColor Gray
    Write-Host ''
    foreach ($item in $plan.Items) {
        $mark = if ($item.Exists) { '[+]' } else { '[ ]' }
        $color = if ($item.Exists) { 'White' } else { 'DarkGray' }
        Write-Host ('    {0} {1}\{2}  {3}' -f $mark, $item.UserName, $item.Folder, $item.Size) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ('  Excluded files: {0}' -f ($exclusions.Files -join ', ')) -ForegroundColor Yellow
    if (@($exclusions.Dirs).Count -gt 0) {
        Write-Host ('  Excluded dirs:  {0}' -f ($exclusions.Dirs -join ', ')) -ForegroundColor Yellow
    }
    if ($includeKeys -or $includeAppData) {
        Write-Host ('  Opt-in scope:   {0}' -f ($optIns -join ', ')) -ForegroundColor Yellow
    }
    if ($appKeys.Count -gt 0) {
        Write-Host ('  App targets:    {0}' -f ($appKeys -join ', ')) -ForegroundColor Yellow
    }
    Write-Host ('  Installed software list: {0}' -f $(if ($captureAppList) { 'yes' } else { 'no' })) -ForegroundColor Yellow

    Write-Host ''
    if ($nonInteractive) {
        $action = if ($BackupExecute) { 'X' } else { 'D' }
    }
    else {
        $action = Select-WinPulseMenuItem -Title 'Dry run (preview) or copy for real?' -Items @(
            @{ Label = 'Dry run - preview only, copies nothing'; Key = 'D'; Hint = 'Recommended first' },
            @{ Label = 'Copy files now';                         Key = 'X'; Hint = 'Writes to destination' },
            @{ Separator = $true },
            @{ Label = 'Cancel';                                 Key = 'C'; Color = 'DarkGray' }
        )
        if ($action -ne 'D' -and $action -ne 'X') {
            Write-Host '  Backup cancelled.' -ForegroundColor Yellow
            return $null
        }
    }
    $dryRun = ($action -eq 'D')

    $hashSampleSize = 0
    if (-not $dryRun) {
        Write-Host ''
        Write-Host ('  About to copy {0} into {1}.' -f $plan.TotalSize, $destinationRoot) -ForegroundColor Yellow
        if (-not $nonInteractive) {
            $confirm = Read-Host '  Type YES to proceed'
            if ($confirm -ne 'YES') {
                Write-Host '  Not confirmed. Backup cancelled.' -ForegroundColor Yellow
                return $null
            }
        }
        if ($nonInteractive) {
            if ($BackupHashSample) { $hashSampleSize = 25 }
        }
        else {
            $hashChoice = Select-WinPulseMenuItem -Title 'Also double-check files by hash?' -Items @(
                @{ Label = 'No - just check file counts and sizes'; Key = 'N'; Hint = 'Faster' },
                @{ Label = 'Yes - compare a sample by hash too';    Key = 'Y'; Hint = 'Slower, stronger' }
            )
            if ($hashChoice -eq 'Y') { $hashSampleSize = 25 }
        }
    }

    New-Item -Path $destinationRoot -ItemType Directory -Force | Out-Null
    $logFolder = Join-Path -Path $destinationRoot -ChildPath 'logs'
    New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
    $logPath = Join-Path -Path $logFolder -ChildPath 'migration-backup.log'
    Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Migration backup started. DryRun={0}, Destination={1}' -f $dryRun, $destinationRoot)

    Write-Host ''
    $results = @()
    $totalItems = @($plan.Items).Count
    $itemIndex = 0
    foreach ($item in $plan.Items) {
        $itemIndex++
        $pct = if ($totalItems -gt 0) { [int]([math]::Floor(($itemIndex - 1) * 100 / $totalItems)) } else { 0 }
        Write-Progress -Activity 'Migration backup' -Status ('Folder {0} of {1}: {2}\{3}' -f $itemIndex, $totalItems, $item.UserName, $item.Folder) -PercentComplete $pct
        if (-not $item.Exists) {
            Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Skip missing source: {0}' -f $item.Source)
            $results += [pscustomobject][ordered]@{ UserName = $item.UserName; Folder = $item.Folder; AppKey = $(if ($item.PSObject.Properties['AppKey']) { $item.AppKey } else { $null }); Relative = $item.Relative; ExtraExcludeFiles = @($item.ExtraExcludeFiles); Source = $item.Source; Destination = $item.Destination; Skipped = $true; Partial = $false; ExitCode = $null; Success = $true; LogPath = $null; Verification = $null; Note = 'Source missing.' }
            continue
        }

        $itemLog = Join-Path -Path $logFolder -ChildPath ('robocopy-{0}-{1}.log' -f $item.UserName, $item.Folder)
        $verb = if ($dryRun) { 'Planning' } else { 'Copying' }
        Write-Host ('  {0} {1}\{2}...' -f $verb, $item.UserName, $item.Folder) -ForegroundColor Gray
        $itemExcludeFiles = @($exclusions.Files) + @($item.ExtraExcludeFiles)
        $rc = Invoke-WinPulseRobocopy -source $item.Source -destination $item.Destination -logPath $itemLog -excludeFiles $itemExcludeFiles -excludeDirs $exclusions.Dirs -DryRun:$dryRun
        $level = if ($rc.Success) { 'INFO' } elseif ($rc.Partial) { 'WARNING' } else { 'ERROR' }
        Write-WinPulseMigrationLog -path $logPath -level $level -message ('{0}\{1} robocopy exit {2}' -f $item.UserName, $item.Folder, $rc.ExitCode)
        if ($rc.Partial) {
            Write-Host ('    some files could not be copied (access-denied/in-use); the rest copied') -ForegroundColor Yellow
        }

        $verify = $null
        if (-not $dryRun -and ($rc.Success -or $rc.Partial)) {
            $verify = Get-WinPulseCopyVerification -source $item.Source -destination $item.Destination -excludeFiles $itemExcludeFiles -excludeDirs $exclusions.Dirs -hashSampleSize $hashSampleSize
            if ($verify.Status -eq 'Mismatch' -and -not $rc.Partial) {
                Write-Host ('    verification mismatch: {0}' -f $verify.Note) -ForegroundColor Yellow
                Write-WinPulseMigrationLog -path $logPath -level 'WARNING' -message ('{0}\{1} verification mismatch: {2}' -f $item.UserName, $item.Folder, $verify.Note)
            }
        }

        $results += [pscustomobject][ordered]@{ UserName = $item.UserName; Folder = $item.Folder; AppKey = $(if ($item.PSObject.Properties['AppKey']) { $item.AppKey } else { $null }); Relative = $item.Relative; ExtraExcludeFiles = @($item.ExtraExcludeFiles); Source = $item.Source; Destination = $item.Destination; Skipped = $false; Partial = [bool]$rc.Partial; ExitCode = $rc.ExitCode; Success = $rc.Success; LogPath = $itemLog; Verification = $verify; Note = $rc.Note }
    }
    Write-Progress -Activity 'Migration backup' -Completed

    $partialItems = @($results | Where-Object { $_.Partial })
    $failed = @($results | Where-Object { -not $_.Success -and -not $_.Partial })
    $mismatch = @($results | Where-Object { $_.Verification -and $_.Verification.Status -eq 'Mismatch' -and -not $_.Partial })
    $appCapture = $null
    if (-not $dryRun -and $captureAppList) {
        Write-Host ''
        Write-Host '  Capturing installed app list...' -ForegroundColor Gray
        $appCapture = Invoke-WinPulseBackupAppCapture -destinationRoot $destinationRoot
        Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('App capture: {0}' -f $appCapture.Note)
    }
    $safetyNotes = @(
        'Explicit user and folder selection only.',
        ('Private keys: {0}; AppData: {1} (opt-in widens scope).' -f $(if ($includeKeys) { 'INCLUDED' } else { 'excluded' }), $(if ($includeAppData) { 'INCLUDED' } else { 'excluded' })),
        'No passwords, DPAPI secrets, or browser secrets are exported.',
        'The installed app capture lists software names and package IDs only; it contains no secrets.',
        $(if ($nonInteractive) { 'Copy step requires explicit -BackupExecute confirmation.' } else { 'Copy step requires explicit YES confirmation.' })
    )
    if ($appKeys -contains 'chrome' -or $appKeys -contains 'firefox') {
        $safetyNotes += 'Browser profiles include the user DPAPI-encrypted credential store; this is an explicit per-app opt-in and encrypted data does not decrypt on another account or machine.'
    }
    $manifest = [pscustomobject][ordered]@{
        Tool            = [pscustomobject][ordered]@{
            Name          = 'WinPulse'
            Version       = $script:WinPulseVersion
            Mode          = 'MigrationBackup'
            Action        = if ($dryRun) { 'DryRun' } else { 'Execute' }
            GeneratedAt   = (Get-Date).ToString('o')
            SchemaVersion = '0.1'
        }
        Computer        = $computerName
        DestinationRoot = $destinationRoot
        Users           = @($userKeys)
        Folders         = @($folderKeys)
        Apps            = @($appKeys)
        OptInCategories = @($optIns)
        Exclusions      = $exclusions
        Plan            = [pscustomobject][ordered]@{
            ItemCount     = $plan.ItemCount
            ExistingCount = $plan.ExistingCount
            TotalBytes    = $plan.TotalBytes
            TotalSize     = $plan.TotalSize
        }
        Items           = @($results)
        FailedCount     = $failed.Count
        PartialCount    = $partialItems.Count
        MismatchCount   = $mismatch.Count
        AppCapture      = $appCapture
        SafetyNotes     = @($safetyNotes)
    }

    $manifestPath = Join-Path -Path $destinationRoot -ChildPath 'manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8
    $reportTextPath = Join-Path -Path $destinationRoot -ChildPath 'migration-backup-report.txt'
    $reportHtmlPath = Join-Path -Path $destinationRoot -ChildPath 'migration-backup-report.html'
    Export-WinPulseMigrationCopyReportText -manifest $manifest -path $reportTextPath
    Export-WinPulseMigrationCopyReportHtml -manifest $manifest -path $reportHtmlPath
    Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Migration backup completed. Failed={0}, Partial={1}, Mismatch={2}' -f $failed.Count, $partialItems.Count, $mismatch.Count)

    # Clean result screen so the outcome is always visible after the copy scrolls
    # by. The per-folder list also reveals a folder that was skipped because its
    # source did not exist (e.g. a redirected/empty Downloads).
    if (-not $nonInteractive) {
        Clear-Host
        Write-WinPulseHeader -title 'Migration Backup - Result'
    }
    Write-Host ''
    foreach ($r in $results) {
        $st = if ($r.Skipped) { 'SKIPPED' } elseif ($r.Partial) { 'PARTIAL' } elseif ($r.Success) { 'OK' } else { 'FAILED' }
        $stColor = if ($r.Skipped) { 'DarkYellow' } elseif ($r.Partial) { 'Yellow' } elseif ($r.Success) { 'Green' } else { 'Red' }
        $detail = if ($r.Skipped) { 'source not found / empty' } elseif ($r.Verification) { '{0} files' -f $r.Verification.DestFiles } else { '' }
        Write-Host ('    {0,-8} {1}\{2}  {3}' -f $st, $r.UserName, $r.Folder, $detail) -ForegroundColor $stColor
    }
    Write-Host ''
    if ($dryRun) {
        Write-Host 'Dry-run plan complete. No files were copied.' -ForegroundColor Green
    }
    elseif ($failed.Count -eq 0 -and $mismatch.Count -eq 0) {
        Write-Host 'Migration backup complete. All folders verified.' -ForegroundColor Green
    }
    elseif ($failed.Count -eq 0) {
        Write-Host ('Migration backup complete, but {0} folder(s) failed verification. Review logs.' -f $mismatch.Count) -ForegroundColor Yellow
    }
    else {
        Write-Host ('Migration backup finished with {0} failed item(s) and {1} verification mismatch(es). Review logs.' -f $failed.Count, $mismatch.Count) -ForegroundColor Yellow
    }
    if ($partialItems.Count -gt 0) {
        Write-Host ('  {0} folder(s) partial: some files could not be copied (access-denied/in-use). The rest copied.' -f $partialItems.Count) -ForegroundColor Yellow
    }
    Write-Host ('  Folder:   {0}' -f $destinationRoot) -ForegroundColor Green
    Write-Host ('  Manifest: {0}' -f $manifestPath) -ForegroundColor Gray
    Write-Host ('  Report:   {0}' -f $reportHtmlPath) -ForegroundColor Gray
    Write-Host ('  Log:      {0}' -f $logPath) -ForegroundColor Gray

    if (-not $nonInteractive) {
        $cmd = @('.\bootstrap.ps1 -Mode MigrationBackup')
        $cmd += '-BackupUsers {0}' -f ((@($userKeys) | ForEach-Object { '"{0}"' -f $_ }) -join ',')
        if ($folderKeys.Count -gt 0) { $cmd += '-BackupFolders {0}' -f ((@($folderKeys) | ForEach-Object { '"{0}"' -f $_ }) -join ',') }
        if ($appKeys.Count -gt 0) { $cmd += '-BackupApps {0}' -f ((@($appKeys) | ForEach-Object { '"{0}"' -f $_ }) -join ',') }
        $cmd += '-BackupDestination "{0}"' -f $destinationRoot
        if ($profileRoot -and $profileRoot -ne 'C:\Users') { $cmd += '-BackupProfilesRoot "{0}"' -f $profileRoot }
        if ($includeKeys) { $cmd += '-BackupIncludePrivateKeys' }
        if ($includeAppData) { $cmd += '-BackupIncludeAppData' }
        if ($hashSampleSize -gt 0) { $cmd += '-BackupHashSample' }
        if (-not $captureAppList) { $cmd += '-SkipBackupAppList' }
        if (-not $dryRun) { $cmd += '-BackupExecute' }
        Write-Host ''
        Write-Host '  To repeat this without prompts:' -ForegroundColor Gray
        Write-Host ('    {0}' -f ($cmd -join ' ')) -ForegroundColor Cyan
    }

    return [pscustomobject][ordered]@{
        DestinationRoot = $destinationRoot
        ManifestPath    = $manifestPath
        ReportTextPath  = $reportTextPath
        ReportHtmlPath  = $reportHtmlPath
        LogPath         = $logPath
        DryRun          = $dryRun
        FailedCount     = $failed.Count
        MismatchCount   = $mismatch.Count
        Manifest        = $manifest
    }
}

# ===========================================================================
# Migration Restore Skeleton
#
# Reads a backup manifest.json, maps backed-up users/folders to restore
# targets, builds a dry-run restore plan, then optionally copies files back
# with the shared robocopy wrapper. Restore stays read-only until the
# technician confirms, and existing targets are flagged before overwrite.
# Restore only moves what the backup chose to keep, so no extra credential or
# private-key material is reintroduced.
# ===========================================================================

function Get-WinPulseRestoreExclusions {
    # Files that must not be restored into known folders. desktop.ini carries
    # folder localization/customization and the system marker for special
    # folders; restoring a backed-up copy can rename or break Desktop/Documents/
    # Pictures and corrupt the profile. thumbs.db is disposable cache.
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        Files = @('desktop.ini', 'thumbs.db')
        Dirs  = @()
        Note  = 'desktop.ini and thumbs.db are not restored, and directory attributes are left untouched, to protect known folders and the profile.'
    }
}

function Get-WinPulseRestoreTargetUserName {
    [CmdletBinding()]
    param(
        [string]$userName
    )

    if ([string]::IsNullOrWhiteSpace($userName)) {
        return $null
    }

    $trimmed = $userName.Trim()
    if ($trimmed -eq '.' -or $trimmed -eq '..' -or ($trimmed.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0)) {
        throw 'Restore target user name must be a single profile folder name.'
    }

    return $trimmed
}

function Read-WinPulseBackupManifest {
    # Reads and validates a backup manifest.json. Returns the parsed object or
    # $null if the file is missing or unreadable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path
    )

    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $manifest -or -not $manifest.PSObject.Properties['Items']) {
        return $null
    }

    return $manifest
}

function Get-WinPulseAvailableBackups {
    # Scans the backups root for folders that contain a manifest.json.
    [CmdletBinding()]
    param()

    $root = $script:WinPulsePaths.Backups
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $backups = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $manifestPath = Join-Path -Path $dir.FullName -ChildPath 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }

        $manifest = Read-WinPulseBackupManifest -path $manifestPath
        if (-not $manifest) { continue }

        $action = 'Unknown'
        if ($manifest.PSObject.Properties['Tool'] -and $manifest.Tool.PSObject.Properties['Action']) {
            $action = [string]$manifest.Tool.Action
        }
        $userCount = if ($manifest.PSObject.Properties['Users']) { @($manifest.Users).Count } else { 0 }
        $totalSize = if ($manifest.PSObject.Properties['Plan'] -and $manifest.Plan.PSObject.Properties['TotalSize']) { [string]$manifest.Plan.TotalSize } else { '' }

        $backups += [pscustomobject][ordered]@{
            Name         = $dir.Name
            Path         = $dir.FullName
            ManifestPath = $manifestPath
            Action       = $action
            UserCount    = $userCount
            TotalSize    = $totalSize
            LastWrite    = ConvertTo-WinPulseDateText -value $dir.LastWriteTime
        }
    }

    return @($backups)
}

function Get-WinPulseManifestItemRelative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$item
    )

    $folder = [string]$item.Folder
    if ($item.PSObject.Properties['Relative'] -and -not [string]::IsNullOrWhiteSpace([string]$item.Relative)) {
        return [string]$item.Relative
    }
    if ([string]::IsNullOrWhiteSpace($folder)) {
        return $null
    }

    $catalog = Get-WinPulseBackupFolderCatalog
    $catEntry = $catalog | Where-Object { $_['Key'] -eq $folder } | Select-Object -First 1
    return $(if ($catEntry) { $catEntry['Relative'] } else { $folder })
}

function Get-WinPulseManifestItemBackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$item,

        [Parameter(Mandatory = $true)]
        [string]$backupRoot
    )

    $userName = [string]$item.UserName
    $relative = Get-WinPulseManifestItemRelative -item $item
    if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($relative)) {
        return $null
    }

    return Join-WinPulsePath -path $backupRoot -childpath @($userName, $relative)
}

function Get-WinPulseVerifyRecordBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$backupRoot,

        [bool]$nonInteractive = $false
    )

    if ($nonInteractive -and -not (Test-WinPulseIsAdmin) -and (Test-WinPulsePathUnderRoot -path $backupRoot -root ([IO.Path]::GetTempPath()))) {
        $backupParent = Split-Path -Path $backupRoot -Parent
        if (-not [string]::IsNullOrWhiteSpace($backupParent)) {
            return (Join-Path -Path $backupParent -ChildPath '_WinPulseVerifyRecords')
        }
    }

    return $script:WinPulsePaths.Backups
}

function ConvertTo-WinPulseStringList {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$values = @()
    )

    $items = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($rawValue in @($values)) {
        if ([string]::IsNullOrWhiteSpace($rawValue)) { continue }
        foreach ($part in ([string]$rawValue -split ',')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $value = $part.Trim()
            $key = $value.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$items.Add($value)
        }
    }

    return $items.ToArray()
}

function Get-WinPulseWingetExportPackageIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $ids = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return $ids.ToArray()
    }

    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $ids.ToArray()
    }

    $data = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $data -or -not $data.PSObject.Properties['Sources']) {
        return $ids.ToArray()
    }

    $seen = @{}
    foreach ($source in @($data.Sources)) {
        if (-not $source -or -not $source.PSObject.Properties['Packages']) { continue }
        foreach ($package in @($source.Packages)) {
            if (-not $package -or -not $package.PSObject.Properties['PackageIdentifier']) { continue }
            $id = [string]$package.PackageIdentifier
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $id = $id.Trim()
            $key = $id.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$ids.Add($id)
        }
    }

    $sorted = New-Object System.Collections.Generic.List[string]
    foreach ($id in ($ids.ToArray() | Sort-Object)) {
        [void]$sorted.Add([string]$id)
    }
    return $sorted.ToArray()
}

function Get-WinPulseMigrationAppsRecordBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$backupRoot,

        [bool]$nonInteractive = $false
    )

    if ($nonInteractive -and -not (Test-WinPulseIsAdmin) -and (Test-WinPulsePathUnderRoot -path $backupRoot -root ([IO.Path]::GetTempPath()))) {
        $backupParent = Split-Path -Path $backupRoot -Parent
        if (-not [string]::IsNullOrWhiteSpace($backupParent)) {
            return (Join-Path -Path $backupParent -ChildPath '_WinPulseAppRecords')
        }
    }

    return $script:WinPulsePaths.Backups
}

function New-WinPulseWingetInstallCommandText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$packageId
    )

    return ('winget install --id {0} -e --accept-package-agreements --accept-source-agreements' -f $packageId)
}

function Invoke-WinPulseMigrationAppReinstall {
    [CmdletBinding()]
    param(
        [string]$AppsBackupPath = $null,
        [switch]$AppsExecute,
        [string[]]$AppsSelect = @()
    )

    $nonInteractive = -not [string]::IsNullOrWhiteSpace($AppsBackupPath)

    Clear-Host
    Write-WinPulseHeader -title 'Migration Apps'
    Write-Host '  Reinstall apps from a backup winget export.' -ForegroundColor Cyan
    Write-Host '  Dry-run is the default; installs require explicit confirmation.' -ForegroundColor Cyan
    Write-Host ''

    $selectedBackupRoot = $null
    if ($nonInteractive) {
        $selectedBackupRoot = $AppsBackupPath.Trim()
    }
    else {
        $backups = @(Get-WinPulseAvailableBackups)
        if ($backups.Count -gt 0) {
            $items = @()
            foreach ($b in $backups) {
                $items += @{
                    Label = ('{0}  [{1}, {2} user(s), {3}]' -f $b.Name, $b.Action, $b.UserCount, $b.TotalSize)
                    Key   = $b.Path
                    Hint  = $b.LastWrite
                }
            }
            $items += @{ Separator = $true }
            $items += @{ Label = 'Enter a path manually'; Key = '__manual__'; Hint = 'External drive, etc.' }

            $choice = Select-WinPulseMenuItem -Title 'Which backup has the app capture?' -Items $items
            if (-not $choice) {
                Write-Host '  App reinstall cancelled.' -ForegroundColor Yellow
                return $null
            }
            if ($choice -ne '__manual__') {
                $selectedBackupRoot = $choice
            }
        }
        else {
            Write-Host '  No local backups with a manifest.json were found.' -ForegroundColor Gray
        }

        if (-not $selectedBackupRoot) {
            $manualInput = Select-WinPulseFolderPath -Title 'Backup folder'
            if ([string]::IsNullOrWhiteSpace($manualInput)) {
                Write-Host '  No path entered. App reinstall cancelled.' -ForegroundColor Yellow
                return $null
            }
            $selectedBackupRoot = $manualInput.Trim()
        }
    }

    $packageFile = Join-WinPulsePath -path $selectedBackupRoot -childpath @('apps', 'winget-packages.json')
    if (-not (Test-Path -LiteralPath $packageFile)) {
        Write-Host ('  winget export not found: {0}' -f $packageFile) -ForegroundColor Yellow
        return [pscustomobject][ordered]@{ BackupRoot = $selectedBackupRoot; PackageFile = $packageFile; SelectedCount = 0; InstalledCount = 0; FailedCount = 0; RecordPath = $null }
    }

    try {
        $packageIds = @(Get-WinPulseWingetExportPackageIds -path $packageFile)
    }
    catch {
        Write-Host ('  Could not parse winget export: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        return [pscustomobject][ordered]@{ BackupRoot = $selectedBackupRoot; PackageFile = $packageFile; SelectedCount = 0; InstalledCount = 0; FailedCount = 0; RecordPath = $null }
    }

    if ($packageIds.Count -eq 0) {
        Write-Host '  winget export did not contain package IDs.' -ForegroundColor Yellow
        return [pscustomobject][ordered]@{ BackupRoot = $selectedBackupRoot; PackageFile = $packageFile; SelectedCount = 0; InstalledCount = 0; FailedCount = 0; RecordPath = $null }
    }

    if ($nonInteractive) {
        $requested = @(ConvertTo-WinPulseStringList -values $AppsSelect)
        if ($requested.Count -gt 0) {
            $requestedSet = @{}
            foreach ($id in @($requested)) {
                $requestedSet[$id.ToLowerInvariant()] = $true
            }
            $selectedIds = @($packageIds | Where-Object { $requestedSet.ContainsKey(([string]$_).ToLowerInvariant()) })
        }
        else {
            $selectedIds = @($packageIds)
        }
    }
    else {
        $alreadyInstalledSet = @{}
        $wingetCmdCheck = Get-Command -Name winget.exe, winget -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wingetCmdCheck) {
            try {
                Write-Host '  Checking installed packages...' -ForegroundColor Gray
                $listRaw = (& ([string]$wingetCmdCheck.Source) list --accept-source-agreements 2>&1 | Out-String)
                foreach ($id in @($packageIds)) {
                    if ($listRaw -match [regex]::Escape($id)) {
                        $alreadyInstalledSet[$id.ToLowerInvariant()] = $true
                    }
                }
            }
            catch {}
        }
        $notInstalledIds  = @($packageIds | Where-Object { -not $alreadyInstalledSet.ContainsKey($_.ToLowerInvariant()) })
        $alreadyInstalledIds = @($packageIds | Where-Object { $alreadyInstalledSet.ContainsKey($_.ToLowerInvariant()) })
        $items = @()
        foreach ($id in $notInstalledIds) {
            $items += @{ Label = $id; Key = $id; Hint = 'not installed'; Color = 'White'; Selected = $true }
        }
        if ($notInstalledIds.Count -gt 0 -and $alreadyInstalledIds.Count -gt 0) {
            $items += @{ Separator = $true; Label = 'already installed' }
        }
        foreach ($id in $alreadyInstalledIds) {
            $items += @{ Label = $id; Key = $id; Hint = 'installed'; Color = 'DarkGray' }
        }
        $selectedIds = @(Select-WinPulseMultiMenuItem -Title 'Which apps should be reinstalled?' -Items $items)
        if ($selectedIds.Count -gt 0) {
            $selInstalled = @($selectedIds | Where-Object { $alreadyInstalledSet.ContainsKey($_.ToLowerInvariant()) }).Count
            $selMissing   = $selectedIds.Count - $selInstalled
            Write-Host ''
            Write-Host ('  Selected: {0}  |  Not installed: {1}  |  Already installed: {2}' -f $selectedIds.Count, $selMissing, $selInstalled) -ForegroundColor Yellow
        }
    }

    if ($selectedIds.Count -eq 0) {
        Write-Host '  No apps selected. App reinstall cancelled.' -ForegroundColor Yellow
        return [pscustomobject][ordered]@{ BackupRoot = $selectedBackupRoot; PackageFile = $packageFile; SelectedCount = 0; InstalledCount = 0; FailedCount = 0; RecordPath = $null }
    }

    if ($nonInteractive) {
        $dryRun = -not $AppsExecute
    }
    else {
        $action = Select-WinPulseMenuItem -Title 'Dry run or install selected apps?' -Items @(
            @{ Label = 'Dry run - print commands only'; Key = 'D'; Hint = 'Default/safe' },
            @{ Label = 'Install selected apps now';     Key = 'X'; Hint = 'Runs winget install' },
            @{ Separator = $true },
            @{ Label = 'Cancel';                        Key = 'C'; Color = 'DarkGray' }
        )
        if ($action -ne 'D' -and $action -ne 'X') {
            Write-Host '  App reinstall cancelled.' -ForegroundColor Yellow
            return $null
        }
        $dryRun = ($action -eq 'D')
    }

    Write-Host ''
    $wingetReady = $false
    $wingetCommand = $null
    if (-not $dryRun) {
        $wingetReady = Ensure-WinGet
        if ($wingetReady) {
            $wingetCommand = Get-Command -Name winget.exe, winget -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }

    $results = @()
    $installIdx = 0
    foreach ($id in @($selectedIds)) {
        $installIdx++
        $commandText = New-WinPulseWingetInstallCommandText -packageId $id
        if ($dryRun) {
            Write-Host ('  DRY RUN: {0}' -f $commandText) -ForegroundColor Cyan
            $results += [pscustomobject][ordered]@{ PackageId = $id; Command = $commandText; DryRun = $true; Success = $true; Status = 'DryRun'; ExitCode = $null; Note = 'Dry run only; winget install was not invoked.' }
            continue
        }

        if (-not $wingetReady -or -not $wingetCommand) {
            Write-Host ('  FAILED: {0} (winget not available)' -f $id) -ForegroundColor Red
            $results += [pscustomobject][ordered]@{ PackageId = $id; Command = $commandText; DryRun = $false; Success = $false; Status = 'Failed'; ExitCode = $null; Note = 'winget is not available.' }
            continue
        }

        Write-Host ('  Installing {0}... ({1}/{2})' -f $id, $installIdx, $selectedIds.Count) -ForegroundColor Gray
        $wingetPath = [string]$wingetCommand.Source
        $output = & $wingetPath install --id $id -e --accept-package-agreements --accept-source-agreements 2>&1
        $exitCode = $LASTEXITCODE
        $outputStr = ($output | Out-String).Trim()
        $wasAlreadyInstalled = ($exitCode -ne 0) -and ($outputStr -imatch 'already installed|No applicable upgrade found')
        $success = ($exitCode -eq 0) -or $wasAlreadyInstalled
        if ($exitCode -eq 0) {
            Write-Host ('    OK: {0}' -f $id) -ForegroundColor Green
        }
        elseif ($wasAlreadyInstalled) {
            Write-Host ('    Already installed: {0}' -f $id) -ForegroundColor DarkGreen
        }
        else {
            Write-Host ('    FAILED: {0} (exit {1})' -f $id, $exitCode) -ForegroundColor Red
        }
        $status = if ($exitCode -eq 0) { 'Installed' } elseif ($wasAlreadyInstalled) { 'AlreadyInstalled' } else { 'Failed' }
        $results += [pscustomobject][ordered]@{ PackageId = $id; Command = $commandText; DryRun = $false; Success = $success; Status = $status; ExitCode = $exitCode; Note = $outputStr }
    }

    $failed = @($results | Where-Object { -not $_.Success })
    $installed = @($results | Where-Object { $_.Success -and -not $_.DryRun })
    $alreadyInstalledItems = @($results | Where-Object { $_.Status -eq 'AlreadyInstalled' })
    $dryRunItems = @($results | Where-Object { $_.DryRun })
    $computerName = Get-WinPulseSafeComputerName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $recordBase = Get-WinPulseMigrationAppsRecordBase -backupRoot $selectedBackupRoot -nonInteractive:$nonInteractive
    $recordRoot = Join-Path -Path $recordBase -ChildPath ('MigrationApps-{0}-{1}' -f $computerName, $stamp)
    $recordSuffix = 1
    while (Test-Path -LiteralPath $recordRoot) {
        $recordSuffix++
        $recordRoot = Join-Path -Path $recordBase -ChildPath ('MigrationApps-{0}-{1}-{2}' -f $computerName, $stamp, $recordSuffix)
    }
    New-Item -Path $recordRoot -ItemType Directory -Force | Out-Null

    $record = [pscustomobject][ordered]@{
        Tool           = [pscustomobject][ordered]@{
            Name          = 'WinPulse'
            Version       = $script:WinPulseVersion
            Mode          = 'MigrationApps'
            Action        = if ($dryRun) { 'DryRun' } else { 'Execute' }
            GeneratedAt   = (Get-Date).ToString('o')
            SchemaVersion = '0.1'
        }
        Computer       = $computerName
        BackupRoot     = $selectedBackupRoot
        PackageFile    = 'apps\winget-packages.json'
        SelectedCount  = @($results).Count
        InstalledCount = $installed.Count
        AlreadyInstalledCount = $alreadyInstalledItems.Count
        FailedCount    = $failed.Count
        DryRunCount    = $dryRunItems.Count
        Items          = @($results)
    }

    $recordPath = Join-Path -Path $recordRoot -ChildPath 'migration-apps.json'
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $recordPath -Encoding UTF8
    $reportTextPath = Join-Path -Path $recordRoot -ChildPath 'migration-apps-report.txt'
    $reportHtmlPath = Join-Path -Path $recordRoot -ChildPath 'migration-apps-report.html'
    Export-WinPulseMigrationAppsReportText -record $record -path $reportTextPath
    Export-WinPulseMigrationAppsReportHtml -record $record -path $reportHtmlPath

    Write-Host ''
    if ($dryRun) {
        Write-Host ('Migration apps dry-run complete. {0} command(s) written; nothing was installed.' -f $dryRunItems.Count) -ForegroundColor Green
    }
    elseif ($failed.Count -eq 0) {
        Write-Host ('Migration apps install complete. Installed: {0}.' -f $installed.Count) -ForegroundColor Green
    }
    else {
        Write-Host ('Migration apps install finished with {0} failure(s). Installed: {1}.' -f $failed.Count, $installed.Count) -ForegroundColor Yellow
    }
    Write-Host ('  Record: {0}' -f $recordPath) -ForegroundColor Gray
    Write-Host ('  Report: {0}' -f $reportHtmlPath) -ForegroundColor Gray

    return [pscustomobject][ordered]@{
        BackupRoot     = $selectedBackupRoot
        PackageFile    = $packageFile
        RecordPath     = $recordPath
        ReportTextPath  = $reportTextPath
        ReportHtmlPath  = $reportHtmlPath
        SelectedCount  = @($results).Count
        InstalledCount = $installed.Count
        FailedCount    = $failed.Count
        DryRunCount    = $dryRunItems.Count
        Record         = $record
    }
}

function Invoke-WinPulseMigrationVerify {
    # Read-only backup integrity check. It only measures files already in the
    # backup and writes a verification record outside the backup payload.
    [CmdletBinding()]
    param(
        [string]$VerifyBackupPath = $null
    )

    $nonInteractive = -not [string]::IsNullOrWhiteSpace($VerifyBackupPath)

    Clear-Host
    Write-WinPulseHeader -title 'Migration Verify'
    Write-Host '  Re-check an existing backup against its manifest.' -ForegroundColor Cyan
    Write-Host '  This only reads the backup and writes a verification record.' -ForegroundColor Cyan
    Write-Host ''

    $selectedBackupRoot = $null
    if ($nonInteractive) {
        $selectedBackupRoot = $VerifyBackupPath.Trim()
    }
    else {
        $backups = @(Get-WinPulseAvailableBackups)

        if ($backups.Count -gt 0) {
            $items = @()
            foreach ($b in $backups) {
                $items += @{
                    Label = ('{0}  [{1}, {2} user(s), {3}]' -f $b.Name, $b.Action, $b.UserCount, $b.TotalSize)
                    Key   = $b.Path
                    Hint  = $b.LastWrite
                }
            }
            $items += @{ Separator = $true }
            $items += @{ Label = 'Enter a path manually'; Key = '__manual__'; Hint = 'External drive, etc.' }

            $choice = Select-WinPulseMenuItem -Title 'Which backup do you want to verify?' -Items $items
            if (-not $choice) {
                Write-Host '  Verify cancelled.' -ForegroundColor Yellow
                return $null
            }
            if ($choice -ne '__manual__') {
                $selectedBackupRoot = $choice
            }
        }
        else {
            Write-Host '  No local backups with a manifest.json were found.' -ForegroundColor Gray
        }

        if (-not $selectedBackupRoot) {
            $manualInput = Select-WinPulseFolderPath -Title 'Backup folder'
            if ([string]::IsNullOrWhiteSpace($manualInput)) {
                Write-Host '  No path entered. Verify cancelled.' -ForegroundColor Yellow
                return $null
            }
            $selectedBackupRoot = $manualInput.Trim()
        }
    }

    $manifestPath = Join-Path -Path $selectedBackupRoot -ChildPath 'manifest.json'
    $manifest = Read-WinPulseBackupManifest -path $manifestPath
    if (-not $manifest) {
        Write-Host ('  Could not read a valid manifest.json under {0}.' -f $selectedBackupRoot) -ForegroundColor Red
        return $null
    }

    Write-Host ('  Backup: {0}' -f $selectedBackupRoot) -ForegroundColor Gray
    Write-Host ''

    $results = @()
    foreach ($entry in @($manifest.Items)) {
        $userName = [string]$entry.UserName
        $folder = [string]$entry.Folder
        $verification = $null
        if ($entry.PSObject.Properties['Verification']) {
            $verification = $entry.Verification
        }

        $recordedFiles = 0
        $recordedBytes = [double]0
        if ($verification -and $verification.PSObject.Properties['DestFiles']) {
            $recordedFiles = [int]$verification.DestFiles
        }
        if ($verification -and $verification.PSObject.Properties['DestBytes']) {
            $recordedBytes = [double]$verification.DestBytes
        }

        $backupPath = Get-WinPulseManifestItemBackupPath -item $entry -backupRoot $selectedBackupRoot
        if (-not $verification -or $recordedFiles -le 0 -or [string]::IsNullOrWhiteSpace($backupPath)) {
            Write-Host ('    [ ] {0}\{1}  skipped (no executed backup data)' -f $userName, $folder) -ForegroundColor Gray
            $results += [pscustomobject][ordered]@{
                UserName      = $userName
                Folder        = $folder
                BackupPath    = $backupPath
                Status        = 'Skipped'
                RecordedFiles = $recordedFiles
                RecordedBytes = $recordedBytes
                CurrentFiles  = $null
                CurrentBytes  = $null
                ShortFiles    = $null
                ShortBytes    = $null
                Note          = 'No executed backup verification data recorded.'
            }
            continue
        }

        $current = Measure-WinPulseFolderFiltered -path $backupPath
        $shortFiles = [math]::Max(0, ($recordedFiles - [int]$current.Files))
        $shortBytes = [math]::Max([double]0, ($recordedBytes - [double]$current.Bytes))
        $status = if ($shortFiles -eq 0 -and $shortBytes -eq 0) { 'Intact' } else { 'Drift' }
        $note = if ($status -eq 'Intact') {
            'Current backup meets or exceeds recorded file and byte counts.'
        }
        else {
            ('Short by {0} files / {1} bytes.' -f $shortFiles, $shortBytes)
        }

        $color = if ($status -eq 'Intact') { 'Green' } else { 'Yellow' }
        $mark = if ($status -eq 'Intact') { '[OK]' } else { '[!]' }
        Write-Host ('    {0} {1}\{2}  {3} (recorded {4} files / {5} bytes, current {6} files / {7} bytes)' -f $mark, $userName, $folder, $status, $recordedFiles, $recordedBytes, $current.Files, $current.Bytes) -ForegroundColor $color

        $results += [pscustomobject][ordered]@{
            UserName      = $userName
            Folder        = $folder
            BackupPath    = $backupPath
            Status        = $status
            RecordedFiles = $recordedFiles
            RecordedBytes = $recordedBytes
            CurrentFiles  = [int]$current.Files
            CurrentBytes  = [double]$current.Bytes
            ShortFiles    = $shortFiles
            ShortBytes    = $shortBytes
            Note          = $note
        }
    }

    $intact = @($results | Where-Object { $_.Status -eq 'Intact' })
    $drift = @($results | Where-Object { $_.Status -eq 'Drift' })
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })
    $computerName = Get-WinPulseSafeComputerName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $recordBase = Get-WinPulseVerifyRecordBase -backupRoot $selectedBackupRoot -nonInteractive:$nonInteractive
    $recordRoot = Join-Path -Path $recordBase -ChildPath ('MigrationVerify-{0}-{1}' -f $computerName, $stamp)
    $recordSuffix = 1
    while (Test-Path -LiteralPath $recordRoot) {
        $recordSuffix++
        $recordRoot = Join-Path -Path $recordBase -ChildPath ('MigrationVerify-{0}-{1}-{2}' -f $computerName, $stamp, $recordSuffix)
    }
    New-Item -Path $recordRoot -ItemType Directory -Force | Out-Null

    $record = [pscustomobject][ordered]@{
        Tool         = [pscustomobject][ordered]@{
            Name          = 'WinPulse'
            Version       = $script:WinPulseVersion
            Mode          = 'MigrationVerify'
            Action        = 'Verify'
            GeneratedAt   = (Get-Date).ToString('o')
            SchemaVersion = '0.1'
        }
        Computer     = $computerName
        BackupRoot   = $selectedBackupRoot
        ManifestPath = $manifestPath
        Items        = @($results)
        ItemCount    = @($results).Count
        IntactCount  = $intact.Count
        DriftCount   = $drift.Count
        SkippedCount = $skipped.Count
        SafetyNotes  = @(
            'MigrationVerify is read-only for the backup payload.',
            'It does not copy, delete, or modify backed-up files.',
            'It compares current backup file and byte counts against the backup manifest.'
        )
    }

    $recordPath = Join-Path -Path $recordRoot -ChildPath 'migration-verify.json'
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $recordPath -Encoding UTF8
    $reportTextPath = Join-Path -Path $recordRoot -ChildPath 'migration-verify-report.txt'
    $reportHtmlPath = Join-Path -Path $recordRoot -ChildPath 'migration-verify-report.html'
    Export-WinPulseMigrationVerifyReportText -record $record -path $reportTextPath
    Export-WinPulseMigrationVerifyReportHtml -record $record -path $reportHtmlPath

    Write-Host ''
    if ($drift.Count -eq 0) {
        Write-Host ('Migration verify complete. Intact: {0}; skipped: {1}; drift: 0.' -f $intact.Count, $skipped.Count) -ForegroundColor Green
    }
    else {
        Write-Host ('Migration verify complete. Drift: {0}; intact: {1}; skipped: {2}.' -f $drift.Count, $intact.Count, $skipped.Count) -ForegroundColor Yellow
    }
    Write-Host ('  Record: {0}' -f $recordPath) -ForegroundColor Gray
    Write-Host ('  Report: {0}' -f $reportHtmlPath) -ForegroundColor Gray

    return [pscustomobject][ordered]@{
        RecordRoot   = $recordRoot
        RecordPath   = $recordPath
        ReportTextPath = $reportTextPath
        ReportHtmlPath = $reportHtmlPath
        IntactCount  = $intact.Count
        DriftCount   = $drift.Count
        SkippedCount = $skipped.Count
        Record       = $record
    }
}

function New-WinPulseRestorePlan {
    # Builds a dry-run restore plan from a manifest. Source paths are rebuilt
    # under the selected backup root so a moved backup folder still resolves.
    # Read-only: it only measures sources and checks for existing targets.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$manifest,

        [Parameter(Mandatory = $true)]
        [string]$backupRoot,

        [Parameter(Mandatory = $true)]
        [string]$restoreRoot,

        [string]$targetUserName = $null
    )

    $targetUserName = Get-WinPulseRestoreTargetUserName -userName $targetUserName
    $items = @()
    $totalBytes = [double]0

    foreach ($entry in @($manifest.Items)) {
        $userName = [string]$entry.UserName
        $folder = [string]$entry.Folder
        if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($folder)) { continue }

        $relative = Get-WinPulseManifestItemRelative -item $entry
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $targetUser = if ([string]::IsNullOrWhiteSpace($targetUserName)) { $userName } else { $targetUserName }

        $source = Join-WinPulsePath -path $backupRoot -childpath @($userName, $relative)
        $target = Join-WinPulsePath -path $restoreRoot -childpath @($targetUser, $relative)
        $size = Get-WinPulsePathSize -path $source
        $targetExists = Test-Path -LiteralPath $target

        $items += [pscustomobject][ordered]@{
            UserName    = $userName
            Folder      = $folder
            Relative    = $relative
            Source      = $source
            Target      = $target
            Exists      = [bool]$size.Exists
            TargetExists = [bool]$targetExists
            Bytes       = [double]$size.Bytes
            Size        = $size.Size
        }
        if ($size.Exists) { $totalBytes += [double]$size.Bytes }
    }

    return New-WinPulseRestorePlanObject -items $items -restoreRoot $restoreRoot -targetUserName $targetUserName
}

function New-WinPulseRestorePlanObject {
    # Wraps a set of restore items into a plan object with recomputed totals.
    # Shared by the initial plan build and the per-folder selection filter.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [array]$items,

        [Parameter(Mandatory = $true)]
        [string]$restoreRoot,

        [string]$targetUserName = $null
    )

    $targetUserName = Get-WinPulseRestoreTargetUserName -userName $targetUserName
    $totalBytes = [double]0
    foreach ($item in @($items)) {
        if ($item.Exists) { $totalBytes += [double]$item.Bytes }
    }

    return [pscustomobject][ordered]@{
        RestoreRoot    = $restoreRoot
        RestoreAsUser  = $targetUserName
        Items          = @($items)
        ItemCount      = @($items).Count
        ExistingCount  = @($items | Where-Object { $_.Exists }).Count
        OverwriteCount = @($items | Where-Object { $_.Exists -and $_.TargetExists }).Count
        TotalBytes     = $totalBytes
        TotalSize      = ConvertTo-ReadableSize -bytes $totalBytes
    }
}

function Select-WinPulseRestoreItems {
    # Lets the technician pick which folders to restore. Returns a filtered plan,
    # the original plan unchanged when there is nothing to choose, or $null when
    # the selection was cancelled / nothing was picked.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$plan
    )

    $withData = @($plan.Items | Where-Object { $_.Exists })
    if ($withData.Count -le 1) {
        return $plan
    }

    $items = @()
    foreach ($entry in $withData) {
        $overwrite = if ($entry.TargetExists) { '  [overwrite]' } else { '' }
        $items += @{
            Label = ('{0}\{1}  {2}{3}' -f $entry.UserName, $entry.Folder, $entry.Size, $overwrite)
            Key   = ('{0}||{1}' -f $entry.UserName, $entry.Folder)
            Hint  = $entry.Target
        }
    }

    $selected = @(Select-WinPulseMultiMenuItem -Title 'Which folders to restore?  (Space to tick, Enter to confirm)' -Items $items)
    if ($selected.Count -eq 0) {
        return $null
    }

    $selectedSet = @{}
    foreach ($key in $selected) { $selectedSet[$key] = $true }
    $filtered = @($plan.Items | Where-Object { $selectedSet.ContainsKey(('{0}||{1}' -f $_.UserName, $_.Folder)) })

    return New-WinPulseRestorePlanObject -items $filtered -restoreRoot $plan.RestoreRoot -targetUserName $plan.RestoreAsUser
}

function Invoke-WinPulseMigrationRestore {
    # Orchestrates the restore skeleton: pick a backup, choose a restore root,
    # build a dry-run plan, then optionally copy files back and write a restore
    # result manifest. Read-only until the technician explicitly confirms.
    [CmdletBinding()]
    param(
        [string]$RestoreBackupPath = $null,
        [string]$RestoreRoot = $null,
        [string[]]$RestoreFolders = @(),
        [switch]$RestoreExecute,
        [switch]$RestoreHashSample,
        [string]$RestoreAsUser = $null
    )

    $hasRestoreParameters = (
        -not [string]::IsNullOrWhiteSpace($RestoreBackupPath) -or
        -not [string]::IsNullOrWhiteSpace($RestoreRoot) -or
        -not [string]::IsNullOrWhiteSpace($RestoreAsUser) -or
        @($RestoreFolders).Count -gt 0 -or
        $RestoreExecute -or
        $RestoreHashSample
    )
    $nonInteractive = (
        -not [string]::IsNullOrWhiteSpace($RestoreBackupPath) -and
        -not [string]::IsNullOrWhiteSpace($RestoreRoot)
    )
    if ($hasRestoreParameters -and -not $nonInteractive) {
        throw 'Non-interactive MigrationRestore requires -RestoreBackupPath and -RestoreRoot.'
    }

    Clear-Host
    Write-WinPulseHeader -title 'Migration Restore'
    Write-Host '  Copy files from a backup back into a user profile.' -ForegroundColor Cyan
    Write-Host '  Pick a backup and folders, preview the plan; nothing changes until you type YES.' -ForegroundColor Cyan
    Write-Host '  Files that already exist are flagged first, and Windows known folders stay intact.' -ForegroundColor Cyan
    Write-Host ''

    $selectedBackupRoot = $null

    if ($nonInteractive) {
        $selectedBackupRoot = $RestoreBackupPath.Trim()
    }
    else {
        $backups = @(Get-WinPulseAvailableBackups)

        if ($backups.Count -gt 0) {
            $items = @()
            foreach ($b in $backups) {
                $items += @{
                    Label = ('{0}  [{1}, {2} user(s), {3}]' -f $b.Name, $b.Action, $b.UserCount, $b.TotalSize)
                    Key   = $b.Path
                    Hint  = $b.LastWrite
                }
            }
            $items += @{ Separator = $true }
            $items += @{ Label = 'Enter a path manually'; Key = '__manual__'; Hint = 'External drive, etc.' }

            $choice = Select-WinPulseMenuItem -Title 'Which backup do you want to restore?' -Items $items
            if (-not $choice) {
                Write-Host '  Restore cancelled.' -ForegroundColor Yellow
                return $null
            }
            if ($choice -ne '__manual__') {
                $selectedBackupRoot = $choice
            }
        }
        else {
            Write-Host '  No local backups with a manifest.json were found.' -ForegroundColor Gray
        }

        if (-not $selectedBackupRoot) {
            $manualInput = Select-WinPulseFolderPath -Title 'Backup folder'
            if ([string]::IsNullOrWhiteSpace($manualInput)) {
                Write-Host '  No path entered. Restore cancelled.' -ForegroundColor Yellow
                return $null
            }
            $selectedBackupRoot = $manualInput.Trim()
        }
    }

    $manifestPath = Join-Path -Path $selectedBackupRoot -ChildPath 'manifest.json'
    $manifest = Read-WinPulseBackupManifest -path $manifestPath
    if (-not $manifest) {
        Write-Host ('  Could not read a valid manifest.json under {0}.' -f $selectedBackupRoot) -ForegroundColor Red
        return $null
    }

    $restoreUsers = if ($manifest.PSObject.Properties['Users']) { @($manifest.Users) } else { @() }
    $restoreFolders = if ($manifest.PSObject.Properties['Folders']) { @($manifest.Folders) } else { @() }

    Clear-Host
    Write-WinPulseHeader -title 'Migration Restore'
    Write-Host ('  Backup:  {0}' -f $selectedBackupRoot) -ForegroundColor Gray
    Write-Host ('  Users:   {0}' -f ($restoreUsers -join ', ')) -ForegroundColor Gray
    Write-Host ('  Folders: {0}' -f ($restoreFolders -join ', ')) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Default restore root: C:\Users (restores into C:\Users\<User>\<Folder>)' -ForegroundColor Gray
    if ($nonInteractive) {
        $restoreRoot = $RestoreRoot.Trim()
    }
    else {
        $rootInput = Read-Host '  Restore into where?  (Enter for C:\Users)'
        $restoreRoot = if ([string]::IsNullOrWhiteSpace($rootInput)) { 'C:\Users' } else { $rootInput.Trim() }
    }
    $restoreAsUserInput = if ($nonInteractive) { $RestoreAsUser } else { Read-Host '  Restore into which user name? (Enter = keep original)' }
    try {
        $restoreAsUser = Get-WinPulseRestoreTargetUserName -userName $restoreAsUserInput
    }
    catch {
        if ($nonInteractive) { throw }
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $null
    }

    Write-Host ''
    Write-Host '  Building dry-run restore plan...' -ForegroundColor Gray
    $restoreExclusions = Get-WinPulseRestoreExclusions
    $plan = New-WinPulseRestorePlan -manifest $manifest -backupRoot $selectedBackupRoot -restoreRoot $restoreRoot -targetUserName $restoreAsUser

    if ($plan.ExistingCount -eq 0) {
        Write-Host '  No restorable data found in this backup (was it a dry run?).' -ForegroundColor Yellow
        return $null
    }

    $restoreFolderFilter = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $RestoreFolders) {
        if (-not [string]::IsNullOrWhiteSpace($folder)) {
            [void]$restoreFolderFilter.Add([string]$folder)
        }
    }

    if ($nonInteractive -and $restoreFolderFilter.Count -gt 0) {
        $folderSet = @{}
        foreach ($folder in $restoreFolderFilter.ToArray()) {
            $folderSet[[string]$folder] = $true
        }
        $filtered = @($plan.Items | Where-Object { $folderSet.ContainsKey([string]$_.Folder) })
        $plan = New-WinPulseRestorePlanObject -items $filtered -restoreRoot $plan.RestoreRoot -targetUserName $plan.RestoreAsUser
    }
    elseif (-not $nonInteractive) {
        $plan = Select-WinPulseRestoreItems -plan $plan
    }
    if (-not $plan) {
        Write-Host '  No folders selected. Restore cancelled.' -ForegroundColor Yellow
        return $null
    }

    Write-Host ''
    Write-Host ('  Plan: {0} items, {1} have data, {2} would overwrite, total {3}' -f $plan.ItemCount, $plan.ExistingCount, $plan.OverwriteCount, $plan.TotalSize) -ForegroundColor Cyan
    Write-Host ('  Restore root: {0}' -f $restoreRoot) -ForegroundColor Gray
    if (-not [string]::IsNullOrWhiteSpace($restoreAsUser)) {
        Write-Host ('  Restore as user: {0}' -f $restoreAsUser) -ForegroundColor Gray
    }
    Write-Host ''
    foreach ($item in $plan.Items) {
        if (-not $item.Exists) {
            Write-Host ('    [ ] {0}\{1}  (no data in backup)' -f $item.UserName, $item.Folder) -ForegroundColor Gray
            continue
        }
        $mark = if ($item.TargetExists) { '[!]' } else { '[+]' }
        $color = if ($item.TargetExists) { 'Yellow' } else { 'White' }
        $suffix = if ($item.TargetExists) { '  (target exists - will overwrite)' } else { '' }
        Write-Host ('    {0} {1}\{2}  {3}{4}' -f $mark, $item.UserName, $item.Folder, $item.Size, $suffix) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ('  Not restored: {0} (known-folder attributes left untouched)' -f ($restoreExclusions.Files -join ', ')) -ForegroundColor Yellow

    Write-Host ''
    if ($nonInteractive) {
        $action = if ($RestoreExecute) { 'X' } else { 'D' }
    }
    else {
        $action = Select-WinPulseMenuItem -Title 'Dry run (preview) or restore for real?' -Items @(
            @{ Label = 'Dry run - preview only, copies nothing'; Key = 'D'; Hint = 'Recommended first' },
            @{ Label = 'Restore files now';                      Key = 'X'; Hint = 'Writes into profile' },
            @{ Separator = $true },
            @{ Label = 'Cancel';                                 Key = 'C'; Color = 'DarkGray' }
        )
        if ($action -ne 'D' -and $action -ne 'X') {
            Write-Host '  Restore cancelled.' -ForegroundColor Yellow
            return $null
        }
    }
    $dryRun = ($action -eq 'D')

    $hashSampleSize = 0
    if (-not $dryRun) {
        Write-Host ''
        if ($plan.OverwriteCount -gt 0) {
            Write-Host ('  WARNING: {0} target folder(s) already exist and will be overwritten.' -f $plan.OverwriteCount) -ForegroundColor Yellow
        }
        Write-Host ('  About to restore {0} into {1}.' -f $plan.TotalSize, $restoreRoot) -ForegroundColor Yellow
        if (-not $nonInteractive) {
            $confirm = Read-Host '  Type YES to proceed'
            if ($confirm -ne 'YES') {
                Write-Host '  Not confirmed. Restore cancelled.' -ForegroundColor Yellow
                return $null
            }
        }
        if ($nonInteractive) {
            if ($RestoreHashSample) { $hashSampleSize = 25 }
        }
        else {
            $hashChoice = Select-WinPulseMenuItem -Title 'Also double-check files by hash?' -Items @(
                @{ Label = 'No - just check file counts and sizes'; Key = 'N'; Hint = 'Faster' },
                @{ Label = 'Yes - compare a sample by hash too';    Key = 'Y'; Hint = 'Slower, stronger' }
            )
            if ($hashChoice -eq 'Y') { $hashSampleSize = 25 }
        }
    }

    $computerName = Get-WinPulseSafeComputerName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $restoreRootForRecord = $restoreRoot.TrimEnd('\')
    $recordBase = $script:WinPulsePaths.Backups
    if ($nonInteractive -and -not (Test-WinPulseIsAdmin) -and $restoreRootForRecord -ne 'C:\Users') {
        $recordBase = Join-Path -Path $restoreRoot -ChildPath '_WinPulseRestoreRecords'
    }
    $recordRoot = Join-Path -Path $recordBase -ChildPath ('MigrationRestore-{0}-{1}' -f $computerName, $stamp)
    $logFolder = Join-Path -Path $recordRoot -ChildPath 'logs'
    New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
    $logPath = Join-Path -Path $logFolder -ChildPath 'migration-restore.log'
    Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Migration restore started. DryRun={0}, Backup={1}, RestoreRoot={2}' -f $dryRun, $selectedBackupRoot, $restoreRoot)
    if (-not [string]::IsNullOrWhiteSpace($restoreAsUser)) {
        Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Restore user remap target: {0}' -f $restoreAsUser)
    }

    Write-Host ''
    $results = @()
    $totalItems = @($plan.Items).Count
    $itemIndex = 0
    foreach ($item in $plan.Items) {
        $itemIndex++
        $pct = if ($totalItems -gt 0) { [int]([math]::Floor(($itemIndex - 1) * 100 / $totalItems)) } else { 0 }
        Write-Progress -Activity 'Migration restore' -Status ('Folder {0} of {1}: {2}\{3}' -f $itemIndex, $totalItems, $item.UserName, $item.Folder) -PercentComplete $pct
        if (-not $item.Exists) {
            Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Skip empty source: {0}' -f $item.Source)
            $results += [pscustomobject][ordered]@{ UserName = $item.UserName; Folder = $item.Folder; Relative = $item.Relative; Source = $item.Source; Target = $item.Target; Skipped = $true; Partial = $false; Overwrite = $false; ExitCode = $null; Success = $true; LogPath = $null; Verification = $null; Note = 'No data in backup.' }
            continue
        }

        $itemLog = Join-Path -Path $logFolder -ChildPath ('robocopy-{0}-{1}.log' -f $item.UserName, $item.Folder)
        $verb = if ($dryRun) { 'Planning' } else { 'Restoring' }
        Write-Host ('  {0} {1}\{2}...' -f $verb, $item.UserName, $item.Folder) -ForegroundColor Gray
        $rc = Invoke-WinPulseRobocopy -source $item.Source -destination $item.Target -logPath $itemLog -excludeFiles $restoreExclusions.Files -excludeDirs $restoreExclusions.Dirs -copyDirMetadata:$false -DryRun:$dryRun
        $level = if ($rc.Success) { 'INFO' } elseif ($rc.Partial) { 'WARNING' } else { 'ERROR' }
        Write-WinPulseMigrationLog -path $logPath -level $level -message ('{0}\{1} robocopy exit {2}' -f $item.UserName, $item.Folder, $rc.ExitCode)
        if ($rc.Partial) {
            Write-Host ('    some files could not be copied (access-denied/in-use); the rest copied') -ForegroundColor Yellow
        }

        $verify = $null
        if (-not $dryRun -and ($rc.Success -or $rc.Partial)) {
            $verify = Get-WinPulseCopyVerification -source $item.Source -destination $item.Target -excludeFiles $restoreExclusions.Files -excludeDirs $restoreExclusions.Dirs -hashSampleSize $hashSampleSize
            if ($verify.Status -eq 'Mismatch' -and -not $rc.Partial) {
                Write-Host ('    verification mismatch: {0}' -f $verify.Note) -ForegroundColor Yellow
                Write-WinPulseMigrationLog -path $logPath -level 'WARNING' -message ('{0}\{1} verification mismatch: {2}' -f $item.UserName, $item.Folder, $verify.Note)
            }
        }

        $results += [pscustomobject][ordered]@{ UserName = $item.UserName; Folder = $item.Folder; Relative = $item.Relative; Source = $item.Source; Target = $item.Target; Skipped = $false; Partial = [bool]$rc.Partial; Overwrite = [bool]$item.TargetExists; ExitCode = $rc.ExitCode; Success = $rc.Success; LogPath = $itemLog; Verification = $verify; Note = $rc.Note }
    }
    Write-Progress -Activity 'Migration restore' -Completed

    $partialItems = @($results | Where-Object { $_.Partial })
    $failed = @($results | Where-Object { -not $_.Success -and -not $_.Partial })
    $mismatch = @($results | Where-Object { $_.Verification -and $_.Verification.Status -eq 'Mismatch' -and -not $_.Partial })
    $safetyNotes = @(
        'Restore only copies data that the backup chose to keep.',
        'desktop.ini and thumbs.db are not restored.',
        'Directory attributes are left untouched so known folders are not broken.',
        'Existing targets are flagged before any overwrite.'
    )
    if (-not [string]::IsNullOrWhiteSpace($restoreAsUser)) {
        $safetyNotes += ('Restore user remap is active: original backup users restore under {0}.' -f $restoreAsUser)
    }
    $safetyNotes += $(if ($nonInteractive) { 'Copy step requires explicit -RestoreExecute confirmation.' } else { 'Copy step requires explicit YES confirmation.' })

    $recordProperties = [ordered]@{
        Tool          = [pscustomobject][ordered]@{
            Name          = 'WinPulse'
            Version       = $script:WinPulseVersion
            Mode          = 'MigrationRestore'
            Action        = if ($dryRun) { 'DryRun' } else { 'Execute' }
            GeneratedAt   = (Get-Date).ToString('o')
            SchemaVersion = '0.1'
        }
        Computer      = $computerName
        BackupRoot    = $selectedBackupRoot
        RestoreRoot   = $restoreRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreAsUser)) {
        $recordProperties['RestoreAsUser'] = $restoreAsUser
    }
    $recordProperties['Exclusions'] = $restoreExclusions
    $recordProperties['Plan'] = [pscustomobject][ordered]@{
        ItemCount      = $plan.ItemCount
        ExistingCount  = $plan.ExistingCount
        OverwriteCount = $plan.OverwriteCount
        TotalBytes     = $plan.TotalBytes
        TotalSize      = $plan.TotalSize
    }
    $recordProperties['Items'] = @($results)
    $recordProperties['FailedCount'] = $failed.Count
    $recordProperties['PartialCount'] = $partialItems.Count
    $recordProperties['MismatchCount'] = $mismatch.Count
    $recordProperties['SafetyNotes'] = @($safetyNotes)
    $record = [pscustomobject]$recordProperties

    $recordPath = Join-Path -Path $recordRoot -ChildPath 'migration-restore.json'
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $recordPath -Encoding UTF8
    $reportTextPath = Join-Path -Path $recordRoot -ChildPath 'migration-restore-report.txt'
    $reportHtmlPath = Join-Path -Path $recordRoot -ChildPath 'migration-restore-report.html'
    Export-WinPulseMigrationCopyReportText -manifest $record -path $reportTextPath
    Export-WinPulseMigrationCopyReportHtml -manifest $record -path $reportHtmlPath
    Write-WinPulseMigrationLog -path $logPath -level 'INFO' -message ('Migration restore completed. Failed={0}, Partial={1}, Mismatch={2}' -f $failed.Count, $partialItems.Count, $mismatch.Count)

    if (-not $nonInteractive) {
        Clear-Host
        Write-WinPulseHeader -title 'Migration Restore - Result'
    }
    Write-Host ''
    foreach ($r in $results) {
        $st = if ($r.Skipped) { 'SKIPPED' } elseif ($r.Partial) { 'PARTIAL' } elseif ($r.Success) { 'OK' } else { 'FAILED' }
        $stColor = if ($r.Skipped) { 'DarkYellow' } elseif ($r.Partial) { 'Yellow' } elseif ($r.Success) { 'Green' } else { 'Red' }
        $detail = if ($r.Skipped) { 'no data in backup' } elseif ($r.Verification) { '{0} files' -f $r.Verification.DestFiles } else { '' }
        Write-Host ('    {0,-8} {1}\{2}  {3}' -f $st, $r.UserName, $r.Folder, $detail) -ForegroundColor $stColor
    }
    Write-Host ''
    if ($dryRun) {
        Write-Host 'Dry-run restore plan complete. No files were copied.' -ForegroundColor Green
    }
    elseif ($failed.Count -eq 0 -and $mismatch.Count -eq 0) {
        Write-Host 'Migration restore complete. All folders verified.' -ForegroundColor Green
    }
    elseif ($failed.Count -eq 0) {
        Write-Host ('Migration restore complete, but {0} folder(s) failed verification. Review logs.' -f $mismatch.Count) -ForegroundColor Yellow
    }
    else {
        Write-Host ('Migration restore finished with {0} failed item(s) and {1} verification mismatch(es). Review logs.' -f $failed.Count, $mismatch.Count) -ForegroundColor Yellow
    }
    if ($partialItems.Count -gt 0) {
        Write-Host ('  {0} folder(s) partial: some files could not be copied (access-denied/in-use). The rest were restored.' -f $partialItems.Count) -ForegroundColor Yellow
    }
    Write-Host ('  Record: {0}' -f $recordPath) -ForegroundColor Gray
    Write-Host ('  Report: {0}' -f $reportHtmlPath) -ForegroundColor Gray
    Write-Host ('  Log:    {0}' -f $logPath) -ForegroundColor Gray

    if (-not $nonInteractive) {
        $restoredFolders = @(@($plan.Items) | ForEach-Object { [string]$_.Folder } | Sort-Object -Unique)
        $cmd = @('.\bootstrap.ps1 -Mode MigrationRestore')
        $cmd += '-RestoreBackupPath "{0}"' -f $selectedBackupRoot
        $cmd += '-RestoreRoot "{0}"' -f $restoreRoot
        if (-not [string]::IsNullOrWhiteSpace($restoreAsUser)) { $cmd += '-RestoreAsUser "{0}"' -f $restoreAsUser }
        if ($restoredFolders.Count -gt 0) { $cmd += '-RestoreFolders {0}' -f (($restoredFolders | ForEach-Object { '"{0}"' -f $_ }) -join ',') }
        if ($hashSampleSize -gt 0) { $cmd += '-RestoreHashSample' }
        if (-not $dryRun) { $cmd += '-RestoreExecute' }
        Write-Host ''
        Write-Host '  To repeat this without prompts:' -ForegroundColor Gray
        Write-Host ('    {0}' -f ($cmd -join ' ')) -ForegroundColor Cyan
    }

    return [pscustomobject][ordered]@{
        RecordRoot   = $recordRoot
        RecordPath   = $recordPath
        ReportTextPath = $reportTextPath
        ReportHtmlPath = $reportHtmlPath
        LogPath      = $logPath
        DryRun       = $dryRun
        FailedCount  = $failed.Count
        MismatchCount = $mismatch.Count
        Record       = $record
    }
}

function Show-WinPulseWindows11Readiness {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-WinPulseHeader -title 'Windows 11 Readiness'
    $readiness = Get-WinPulseWindows11Readiness

    $color = switch ($readiness.Recommendation) {
        'Ready' { 'Green' }
        'Needs attention' { 'Yellow' }
        'Not ready' { 'Red' }
        default { 'DarkYellow' }
    }

    Write-Host ('Recommendation : {0}' -f $readiness.Recommendation) -ForegroundColor $color
    Write-Host ('TPM            : present={0}, ready={1}, version={2}' -f $readiness.TPM.Present, $readiness.TPM.Ready, $readiness.TPM.SpecVersion) -ForegroundColor Cyan
    Write-Host ('Secure Boot    : {0}' -f $readiness.SecureBootState) -ForegroundColor Cyan
    Write-Host ('Firmware       : {0}' -f $readiness.FirmwareMode) -ForegroundColor Cyan
    Write-Host ('RAM            : {0}' -f $readiness.RamSize) -ForegroundColor Cyan
    Write-Host ('System Free    : {0}' -f $readiness.SystemDriveFree) -ForegroundColor Cyan
    Write-Host ('CPU            : {0}' -f $readiness.CPUModel) -ForegroundColor Cyan
    Write-Host ('Partition      : {0}' -f $readiness.DiskPartitionStyle) -ForegroundColor Cyan
    Write-Host ('Pending reboot : {0}' -f $readiness.PendingReboot) -ForegroundColor Cyan

    if ($readiness.Blockers.Count -gt 0) {
        Write-Host ''
        Write-Host 'Blockers:' -ForegroundColor Red
        foreach ($item in $readiness.Blockers) { Write-Host ('- {0}' -f $item) -ForegroundColor Red }
    }
    if ($readiness.Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach ($item in $readiness.Warnings) { Write-Host ('- {0}' -f $item) -ForegroundColor Yellow }
    }
    if ($readiness.Unknowns.Count -gt 0) {
        Write-Host ''
        Write-Host 'Unknown signals:' -ForegroundColor Yellow
        foreach ($item in $readiness.Unknowns) { Write-Host ('- {0}' -f $item) -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host $readiness.Note -ForegroundColor Gray
}

function Export-WinPulseLatestBundle {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -Path $script:WinPulsePaths.Exports)) {
        throw 'WinPulse exports folder does not exist yet.'
    }

    $latestFolder = Get-ChildItem -Path $script:WinPulsePaths.Exports -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestFolder) {
        throw 'No export folders were found to bundle.'
    }

    $zipPath = Join-Path -Path $script:WinPulsePaths.Exports -ChildPath ('WinPulseBundle-{0}-{1}.zip' -f (Get-WinPulseSafeComputerName), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (Get-Command -Name Compress-Archive -ErrorAction SilentlyContinue) {
        Compress-Archive -Path $latestFolder.FullName -DestinationPath $zipPath -Force
    }
    else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::CreateFromDirectory($latestFolder.FullName, $zipPath)
    }

    Write-Host ('Export bundle created: {0}' -f $zipPath) -ForegroundColor Green
    return $zipPath
}

function Show-WindowsUpdateErrorDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    if (-not $scan.Health.WindowsUpdateRecentErrors -or $scan.Health.WindowsUpdateRecentErrors.Count -eq 0) {
        Write-Host 'No Windows Update errors found in the last 24 hours.' -ForegroundColor Green
        return
    }

    Write-Host 'Windows Update errors (last 24h):' -ForegroundColor Yellow
    foreach ($item in $scan.Health.WindowsUpdateRecentErrors) {
        Write-Host ('[{0}] EventID:{1} Code:{2} Category:{3}' -f $item.Time.ToString('yyyy-MM-dd HH:mm:ss'), $item.EventId, $item.Code, $item.Category) -ForegroundColor Yellow
        Write-Host ('  {0}' -f $item.Message)
    }
}

function Show-WinPulseEventLogInspection {
    [CmdletBinding()]
    param(
        [int]$hourback = 24,
        [int]$maxitems = 12
    )

    Write-WinPulseHeader -title 'Inspect Logs'
    $since = (Get-Date).AddHours(-1 * [math]::Abs($hourback))
    Write-Host ('Showing critical/error events since: {0}' -f $since.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Yellow

    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
                LogName   = @('System', 'Application')
                Level     = @([int]1, [int]2)
                StartTime = $since
            } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending | Select-Object -First $maxitems)
    }
    catch {
        Write-Host ('Event log read failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    if ($events.Count -eq 0) {
        Write-Host 'No critical/error events found in selected window.' -ForegroundColor Green
        return
    }

    foreach ($evt in $events) {
        $msg = ''
        if ($evt.Message) {
            $msg = ($evt.Message -replace '\s+', ' ').Trim()
        }
        if ($msg.Length -gt 160) {
            $msg = $msg.Substring(0, 160) + '...'
        }

        Write-Host ('[{0}] {1} | {2} | ID {3} | {4}' -f $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $evt.LogName, $evt.ProviderName, $evt.Id, $evt.LevelDisplayName) -ForegroundColor Yellow
        if ($msg) {
            Write-Host ('  {0}' -f $msg) -ForegroundColor Gray
        }
    }
}

function Get-WinPulseToolCatalog {
    [CmdletBinding()]
    param()

    return @{
        BlueScreenView = [ordered]@{
            Url = 'https://www.nirsoft.net/utils/bluescreenview.zip'
            Binary = 'BlueScreenView.exe'
        }
        Autoruns = [ordered]@{
            Url = 'https://download.sysinternals.com/files/Autoruns.zip'
            Binary = 'Autoruns64.exe'
        }
        OpenHardwareMonitor = [ordered]@{
            Url = 'https://openhardwaremonitor.org/files/openhardwaremonitor-v0.9.6.zip'
            Binary = 'OpenHardwareMonitor.exe'
        }
        CrystalDiskInfo = [ordered]@{
            Urls = @(
                'https://www.majorgeeks.com/files/details/crystaldiskinfo_portable.html'
            )
            BinaryCandidates = @('DiskInfo64.exe', 'DiskInfo32.exe', 'CrystalDiskInfo64.exe', 'CrystalDiskInfo32.exe', 'CrystalDiskInfo.exe')
        }
        StressMyPC = [ordered]@{
            Urls = @(
                'https://www.softwareok.com/Download/StressMyPC.zip',
                'https://www.softwareok.com/?seite=Microsoft/StressMyPC',
                'https://www.softwareok.eu/?seite=Microsoft/StressMyPC'
            )
            BinaryCandidates = @('StressMyPC_x64.exe', 'StressMyPC.exe')
        }
        TechToolStore = [ordered]@{
            Url = 'https://www.carifred.com/tech_tool_store/TechToolStore.exe'
            BinaryCandidates = @('TechToolStore.exe')
        }
        NirLauncher = [ordered]@{
            Urls = @(
                'https://www.nirsoft.net/utils/nirlauncher_package.zip',
                'https://www.nirsoft.net/utils/nirlauncher.zip',
                'http://files.npackd.org/net.nirsoft.Launcher/net.nirsoft.Launcher-1.19.57.zip'
            )
            BinaryCandidates = @('NirLauncher.exe')
        }
        OOShutUp10 = [ordered]@{
            Urls = @(
                'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe'
            )
            BinaryCandidates = @('OOSU10.exe')
        }
        SysinternalsSuite = [ordered]@{
            Url = 'https://download.sysinternals.com/files/SysinternalsSuite.zip'
            BinaryCandidates = @('procexp64.exe', 'procexp.exe', 'procmon64.exe', 'procmon.exe')
        }
    }
}

function Resolve-WinPulseDownloadUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$sourceurl,

        [string]$toolname = '',
        [int]$depth = 0
    )

    if ($sourceurl -match '\.(zip|exe)(\?|$)') {
        return $sourceurl
    }

    try {
        $resp = Invoke-WebRequest -Uri $sourceurl -UseBasicParsing -ErrorAction Stop
        $candidateLinks = @()
        if ($resp.Links) {
            $candidateLinks += @($resp.Links | ForEach-Object { $_.href } | Where-Object { $_ })
        }
        if ($resp.Content) {
            $candidateLinks += @([regex]::Matches($resp.Content, 'href\s*=\s*["''][^"'']+["'']', 'IgnoreCase') | ForEach-Object {
                    $_.Value -replace '^href\s*=\s*["'']', '' -replace '["'']$', ''
                })
        }

        $resolvedLinks = @()
        foreach ($href in $candidateLinks) {
            if ([string]::IsNullOrWhiteSpace($href)) { continue }
            try {
                $uri = [Uri]::new([Uri]$sourceurl, $href)
                $resolvedLinks += $uri.AbsoluteUri
            }
            catch {
            }
        }

        $patterns = @()
        if ($toolname -eq 'CrystalDiskInfo') {
            $patterns = @('crystaldiskinfo.*portable.*\.(zip|exe)', 'crystaldiskinfo.*\.(zip|exe)')
        }
        elseif ($toolname -eq 'FurMarkPortable') {
            $patterns = @('furmark.*win64.*\.(zip|exe)', 'furmark.*\.(zip|exe)')
        }
        elseif ($toolname -eq 'StressMyPC') {
            $patterns = @('stressmypc.*\.(zip|exe)', '\bstressmypc\.zip(\?|$)')
        }
        else {
            $patterns = @("$([regex]::Escape($toolname)).*\.(zip|exe)", '\.(zip|exe)(\?|$)')
        }

        foreach ($pattern in $patterns) {
            $match = $resolvedLinks | Where-Object { $_ -match $pattern } | Select-Object -First 1
            if ($match) {
                return $match
            }
        }

        if ($depth -lt 1) {
            $jumpLink = $resolvedLinks | Where-Object {
                $_ -match 'majorgeeks\.com/.*/(getmirror|getsoft)/' -or
                $_ -match 'download'
            } | Select-Object -First 1
            if ($jumpLink) {
                return (Resolve-WinPulseDownloadUrl -sourceurl $jumpLink -toolname $toolname -depth ($depth + 1))
            }
        }
    }
    catch {
    }

    return $null
}

function Ensure-ToolInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$name
    )

    $catalog = Get-WinPulseToolCatalog
    if (-not $catalog.ContainsKey($name)) {
        throw "Unknown tool: $name"
    }

    $tool = $catalog[$name]
    $targetDir = Join-Path $script:WinPulsePaths.Bin $name
    $binaryCandidates = @()
    if ($tool.PSObject.Properties['BinaryCandidates'] -and $tool.BinaryCandidates) {
        $binaryCandidates = @($tool.BinaryCandidates)
    }
    elseif ($tool.PSObject.Properties['Binary'] -and $tool.Binary) {
        $binaryCandidates = @($tool.Binary)
    }

    foreach ($candidate in $binaryCandidates) {
        $binaryPath = Join-Path $targetDir $candidate
        if (Test-Path -Path $binaryPath) {
            return $binaryPath
        }
    }

    if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    $downloadSources = @()
    if ($tool.PSObject.Properties['Urls'] -and $tool.Urls) {
        $downloadSources = @($tool.Urls)
    }
    elseif ($tool.PSObject.Properties['Url'] -and $tool.Url) {
        $downloadSources = @($tool.Url)
    }

    $downloadSucceeded = $false
    foreach ($source in $downloadSources) {
        $directUrl = Resolve-WinPulseDownloadUrl -sourceurl $source -toolname $name
        if (-not $directUrl) {
            continue
        }

        $ext = '.bin'
        try {
            $fileName = [System.IO.Path]::GetFileName(([Uri]$directUrl).AbsolutePath)
            $tmpExt = [System.IO.Path]::GetExtension($fileName)
            if ($tmpExt) {
                $ext = $tmpExt
            }
        }
        catch {
        }

        $downloadPath = Join-Path $script:WinPulsePaths.Bin ("{0}-{1}{2}" -f $name, ([Guid]::NewGuid().ToString('N')), $ext)
        try {
            Write-Log -level 'INFO' -message ("Downloading tool {0} from {1}" -f $name, $directUrl)
            Invoke-WebRequest -Uri $directUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop

            if ($downloadPath -match '\.zip$') {
                $isZip = $false
                try {
                    $probe = [IO.File]::OpenRead($downloadPath)
                    try {
                        if ($probe.Length -ge 4) {
                            $sig = New-Object byte[] 4
                            [void]$probe.Read($sig, 0, 4)
                            $isZip = ($sig[0] -eq 0x50 -and $sig[1] -eq 0x4B)
                        }
                    }
                    finally {
                        $probe.Dispose()
                    }
                }
                catch {
                }
                if (-not $isZip) {
                    throw 'Downloaded file is not a valid ZIP archive.'
                }
                Expand-Archive -Path $downloadPath -DestinationPath $targetDir -Force
            }
            elseif ($downloadPath -match '\.exe$') {
                $destinationExe = Join-Path $targetDir ([System.IO.Path]::GetFileName($downloadPath))
                Copy-Item -Path $downloadPath -Destination $destinationExe -Force
            }

            $downloadSucceeded = $true
            Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue
            break
        }
        catch {
            Write-Log -level 'WARNING' -message ("Download attempt failed for {0} ({1}): {2}" -f $name, $directUrl, $_.Exception.Message)
            Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $downloadSucceeded) {
        throw "Failed to download $name from configured sources."
    }

    $resolved = $null
    foreach ($candidate in $binaryCandidates) {
        $resolved = Get-ChildItem -Path $targetDir -Recurse -File | Where-Object { $_.Name -eq $candidate } | Select-Object -First 1
        if ($resolved) {
            break
        }
    }
    if (-not $resolved) {
        $resolved = Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.exe' -and $_.Name -match [regex]::Escape($name) } |
            Select-Object -First 1
    }
    if (-not $resolved) {
        $resolved = Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.exe' } |
            Select-Object -First 1
    }
    if (-not $resolved) {
        throw "Downloaded $name but expected binary was not found."
    }

    return $resolved.FullName
}

function Find-WinPulseExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$filenames,

        [string[]]$hintfolders = @()
    )

    $roots = @($script:WinPulsePaths.Bin, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ -and (Test-Path -Path $_) }

    foreach ($root in $roots) {
        foreach ($hint in $hintfolders) {
            $hintPath = Join-Path $root $hint
            if (-not (Test-Path -Path $hintPath)) { continue }
            foreach ($file in $filenames) {
                $candidate = Get-ChildItem -Path $hintPath -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq $file } |
                    Select-Object -First 1
                if ($candidate) { return $candidate.FullName }
            }
        }
    }

    foreach ($root in $roots) {
        foreach ($file in $filenames) {
            $candidate = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $file } |
                Select-Object -First 1
            if ($candidate) { return $candidate.FullName }
        }
    }

    return $null
}

function Install-WinPulseWingetCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ids
    )

    if (-not (Test-WinGetAvailable)) {
        return $null
    }

    foreach ($id in $ids) {
        $output = & winget install --id $id --exact --disable-interactivity --accept-source-agreements --accept-package-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log -level 'INFO' -message ("winget installed {0}" -f $id)
            return $id
        }
        Write-Log -level 'WARNING' -message ("winget install failed for {0}: {1}" -f $id, (($output | Out-String).Trim()))
    }

    return $null
}

function Start-WinPulseAppByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$namepattern
    )

    try {
        $startApp = Get-StartApps | Where-Object { $_.Name -match $namepattern } | Select-Object -First 1
        if ($startApp -and $startApp.AppID) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ("shell:AppsFolder\{0}" -f $startApp.AppID) | Out-Null
            return $true
        }
    }
    catch {
    }

    try {
        $appx = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match $namepattern -or $_.PackageFamilyName -match $namepattern
        } | Select-Object -First 1
        if ($appx -and $appx.InstallLocation) {
            $manifestPath = Join-Path $appx.InstallLocation 'AppxManifest.xml'
            if (Test-Path -Path $manifestPath) {
                [xml]$manifest = Get-Content -Path $manifestPath -ErrorAction SilentlyContinue
                $appId = $manifest.Package.Applications.Application.Id | Select-Object -First 1
                if ($appId) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ("shell:AppsFolder\{0}!{1}" -f $appx.PackageFamilyName, $appId) | Out-Null
                    return $true
                }
            }
        }
    }
    catch {
    }

    return $false
}

function Start-WinPulseAutoruns {
    [CmdletBinding()]
    param()

    try {
        $toolPath = Ensure-ToolInstalled -name 'Autoruns'
        Start-Process -FilePath $toolPath
        return
    }
    catch {
        Write-Log -level 'WARNING' -message ("Autoruns portable failed: {0}" -f $_.Exception.Message)
    }

    [void](Install-WinPulseWingetCandidates -ids @('Microsoft.Sysinternals.Autoruns'))
    $exe = Find-WinPulseExecutable -filenames @('Autoruns64.exe', 'Autoruns.exe') -hintfolders @('Sysinternals', 'Autoruns')
    if ($exe) {
        Start-Process -FilePath $exe
        return
    }

    if (-not (Start-WinPulseAppByName -namepattern 'Autoruns')) {
        Write-Host 'Autoruns launch failed (portable + winget fallback).' -ForegroundColor Red
    }
}

function Start-WinPulseBlueScreenView {
    [CmdletBinding()]
    param()

    $directUrl = 'https://www.nirsoft.net/utils/bluescreenview.zip'
    $targetDir = Join-Path $script:WinPulsePaths.Bin 'BlueScreenView'
    $targetExe = Join-Path $targetDir 'BlueScreenView.exe'

    if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -Path $targetExe)) {
        $zipPath = Join-Path $script:WinPulsePaths.Bin ('BlueScreenView-{0}.zip' -f ([Guid]::NewGuid().ToString('N')))
        try {
            Invoke-WebRequest -Uri $directUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force
        }
        catch {
            Write-Host ('BlueScreenView download failed (direct link): {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-Host ('Direct link: {0}' -f $directUrl) -ForegroundColor Yellow
            return
        }
        finally {
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -Path $targetExe) {
        Start-Process -FilePath $targetExe
        return
    }

    Write-Host 'BlueScreenView.exe not found in downloaded ZIP.' -ForegroundColor Red
    Write-Host ('Direct link used: {0}' -f $directUrl) -ForegroundColor Yellow
}

function Start-WinPulseOpenHardwareMonitor {
    [CmdletBinding()]
    param()

    try {
        $toolPath = Ensure-ToolInstalled -name 'OpenHardwareMonitor'
        Start-Process -FilePath $toolPath
        return
    }
    catch {
        Write-Log -level 'WARNING' -message ("OpenHardwareMonitor portable failed: {0}" -f $_.Exception.Message)
    }

    [void](Install-WinPulseWingetCandidates -ids @('OpenHardwareMonitor.OpenHardwareMonitor', 'LibreHardwareMonitor.LibreHardwareMonitor'))
    $exe = Find-WinPulseExecutable -filenames @('OpenHardwareMonitor.exe', 'LibreHardwareMonitor.exe') -hintfolders @('OpenHardwareMonitor', 'LibreHardwareMonitor')
    if ($exe) {
        Start-Process -FilePath $exe
        return
    }

    if (-not (Start-WinPulseAppByName -namepattern 'OpenHardwareMonitor|LibreHardwareMonitor')) {
        Write-Host 'OpenHardwareMonitor launch failed (portable + winget fallback).' -ForegroundColor Red
    }
}

function Start-WinPulseTechToolStore {
    [CmdletBinding()]
    param()

    $directUrl = 'https://www.carifred.com/tech_tool_store/TechToolStore.exe'
    $targetDir = Join-Path $script:WinPulsePaths.Bin 'TechToolStore'
    $targetExe = Join-Path $targetDir 'TechToolStore.exe'
    if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -Path $targetExe)) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        catch {
        }

        $downloaded = $false
        try {
            Invoke-WebRequest -Uri $directUrl -OutFile $targetExe -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
        }
        catch {
        }

        if (-not $downloaded) {
            try {
                Start-BitsTransfer -Source $directUrl -Destination $targetExe -ErrorAction Stop
                $downloaded = $true
            }
            catch {
            }
        }

        if (-not $downloaded) {
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
                $wc.DownloadFile($directUrl, $targetExe)
                $downloaded = $true
            }
            catch {
            }
        }
    }

    if (Test-Path -Path $targetExe) {
        Start-Process -FilePath $targetExe
        return
    }

    try {
        $toolPath = Ensure-ToolInstalled -name 'TechToolStore'
        Start-Process -FilePath $toolPath
        return
    }
    catch {
        Write-Host ('TechToolStore download failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    $existing = Find-WinPulseExecutable -filenames @('TechToolStore.exe') -hintfolders @('TechToolStore')
    if ($existing) {
        Start-Process -FilePath $existing
        return
    }

    Write-Host 'Opening official TechToolStore page for manual download...' -ForegroundColor Cyan
    Start-Process 'https://www.carifred.com/tech_tool_store/'
}

function Start-WinPulseNirLauncher {
    [CmdletBinding()]
    param()

    try {
        $toolPath = Ensure-ToolInstalled -name 'NirLauncher'
        Start-Process -FilePath $toolPath
        return
    }
    catch {
        Write-Log -level 'WARNING' -message ("NirLauncher portable failed: {0}" -f $_.Exception.Message)
    }

    [void](Install-WinPulseWingetCandidates -ids @('NirSoft.NirLauncher'))
    $exe = Find-WinPulseExecutable -filenames @('NirLauncher.exe') -hintfolders @('NirLauncher', 'NirSoft')
    if ($exe) {
        Start-Process -FilePath $exe
        return
    }

    Write-Host 'NirLauncher launch failed (portable + winget fallback). Opening official page...' -ForegroundColor Yellow
    Start-Process 'https://www.nirsoft.net/launcher/'
}

function Start-WinPulseOOShutUp {
    [CmdletBinding()]
    param()

    Write-Host 'O&O ShutUp10++ can change privacy/policy settings. Review options before applying.' -ForegroundColor Yellow

    $targetDir = Join-Path $script:WinPulsePaths.Bin 'OOShutUp10'
    if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }
    $targetExe = Join-Path $targetDir 'OOSU10.exe'

    if (-not (Test-Path -Path $targetExe)) {
        $directUrl = 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe'
        try {
            Invoke-WebRequest -Uri $directUrl -OutFile $targetExe -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-Host ('O&O direct download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-Host ('Direct link: {0}' -f $directUrl) -ForegroundColor Yellow
            return
        }
    }

    if (Test-Path -Path $targetExe) {
        Start-Process -FilePath $targetExe
        return
    }

    Write-Host 'O&O executable not found after direct download.' -ForegroundColor Red
    Write-Host 'Direct link used: https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -ForegroundColor Yellow
}

function Start-WinPulseSysinternalsSuite {
    [CmdletBinding()]
    param()

    $targetDir = Join-Path $script:WinPulsePaths.Bin 'SysinternalsLive'
    if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    $primaryPath = Join-Path $targetDir 'procexp64.exe'
    $fallbackPath = Join-Path $targetDir 'procexp.exe'

    if (-not (Test-Path -Path $primaryPath) -and -not (Test-Path -Path $fallbackPath)) {
        try {
            Invoke-WebRequest -Uri 'https://live.sysinternals.com/procexp64.exe' -OutFile $primaryPath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            try {
                Invoke-WebRequest -Uri 'https://live.sysinternals.com/procexp.exe' -OutFile $fallbackPath -UseBasicParsing -ErrorAction Stop
            }
            catch {
                Write-Host ('Process Explorer download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
                return
            }
        }
    }

    $exePath = $null
    if (Test-Path -Path $primaryPath) {
        $exePath = $primaryPath
    }
    elseif (Test-Path -Path $fallbackPath) {
        $exePath = $fallbackPath
    }

    if ($exePath) {
        try {
            Write-Host ('Starting Process Explorer: {0}' -f $exePath) -ForegroundColor Cyan
            Start-Process -FilePath $exePath
        }
        catch {
            Write-Host ('Process Explorer start failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function Start-DeepDiskAnalysis {
    [CmdletBinding()]
    param()

    if (-not (Test-WinGetAvailable)) {
        Write-Host 'winget is required for CrystalDiskInfo install/run/uninstall flow.' -ForegroundColor Red
        return
    }

    $installedPackageId = $null
    $packageCandidates = @('CrystalDewWorld.CrystalDiskInfo')
    $lastInstallError = $null
    try {
        foreach ($pkg in $packageCandidates) {
            try {
                $listOutput = & winget list --id $pkg --exact 2>&1
                if (($listOutput | Out-String) -match [regex]::Escape($pkg)) {
                    $installedPackageId = $pkg
                    break
                }
            }
            catch {
            }
        }

        if (-not $installedPackageId) {
            Write-Host 'Installing CrystalDiskInfo via winget...' -ForegroundColor Cyan
            foreach ($pkg in $packageCandidates) {
                $installOutput = & winget install --id $pkg --exact --disable-interactivity --accept-source-agreements --accept-package-agreements --silent 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $installedPackageId = $pkg
                    break
                }
                $lastInstallError = ($installOutput | Out-String).Trim()
            }

            if (-not $installedPackageId) {
                throw ("winget install failed for CrystalDiskInfo. Last error: {0}" -f $lastInstallError)
            }
        }
        else {
            Write-Host ("Using existing CrystalDiskInfo package: {0}" -f $installedPackageId) -ForegroundColor Yellow
        }

        $exe = $null
        $exactNames = @(
            'DiskInfo64.exe', 'DiskInfo32.exe', 'DiskInfoA64.exe',
            'CrystalDiskInfo64.exe', 'CrystalDiskInfo32.exe', 'CrystalDiskInfo.exe'
        )

        $explicitCandidates = @(
            (Join-Path $env:ProgramFiles 'CrystalDiskInfo\DiskInfo64.exe'),
            (Join-Path $env:ProgramFiles 'CrystalDiskInfo\DiskInfo32.exe'),
            (Join-Path $env:ProgramFiles 'CrystalDiskInfo\DiskInfoA64.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'CrystalDiskInfo\DiskInfo64.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'CrystalDiskInfo\DiskInfo32.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'CrystalDiskInfo\DiskInfoA64.exe')
        )

        foreach ($path in $explicitCandidates) {
            if ($path -and (Test-Path -Path $path)) {
                $exe = Get-Item -Path $path -ErrorAction SilentlyContinue
                if ($exe) { break }
            }
        }

        if (-not $exe) {
            $wingetPackagesRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
            if (Test-Path -Path $wingetPackagesRoot) {
                $exe = (Get-ChildItem -Path $wingetPackagesRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -imatch '^CrystalDewWorld\.CrystalDiskInfo_' } |
                    ForEach-Object {
                        Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Where-Object {
                                $_.Extension -ieq '.exe' -and (
                                    $_.Name -in $exactNames -or
                                    $_.Name -imatch '^DiskInfo.*\.exe$' -or
                                    $_.Name -imatch '^CrystalDiskInfo.*\.exe$'
                                )
                            } |
                            Select-Object -First 1
                    } |
                    Select-Object -First 1)
            }
        }

        if (-not $exe) {
            $exe = (Get-ChildItem -Path @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension -ieq '.exe' -and (
                        $_.Name -in $exactNames -or
                        $_.Name -imatch '^DiskInfo.*\.exe$' -or
                        $_.Name -imatch '^CrystalDiskInfo.*\.exe$'
                    )
                } |
                Select-Object -First 1)
        }

        if (-not $exe) {
            throw 'CrystalDiskInfo executable was not found after winget installation.'
        }

        Write-Host ("Launching: {0}" -f $exe.FullName) -ForegroundColor Cyan
        $proc = Start-Process -FilePath $exe.FullName -PassThru
        if ($proc) {
            Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Host ('CrystalDiskInfo failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        if ($installedPackageId) {
            Write-Host 'Uninstalling CrystalDiskInfo package...' -ForegroundColor Cyan
            try {
                $uninstallOutput = & winget uninstall --id $installedPackageId --exact --disable-interactivity --silent 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host ('CrystalDiskInfo uninstall warning: {0}' -f (($uninstallOutput | Out-String).Trim())) -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host ('CrystalDiskInfo uninstall warning: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }
}

function Show-WinPulseSmartSummary {
    [CmdletBinding()]
    param()

    Write-WinPulseHeader -title 'SMART Summary'

    $entries = @()
    try {
        $smartStatus = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue)
        if ($smartStatus.Count -gt 0) {
            foreach ($item in $smartStatus) {
                $instance = [string]$item.InstanceName
                $diskId = ($instance -split '_')[0]
                $entries += [pscustomobject]@{
                    Disk = $diskId
                    PredictFailure = [bool]$item.PredictFailure
                    Source = 'MSStorageDriver_FailurePredictStatus'
                }
            }
        }
    }
    catch {
    }

    if ($entries.Count -eq 0) {
        try {
            $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
            foreach ($disk in $physical) {
                $entries += [pscustomobject]@{
                    Disk = if ($disk.FriendlyName) { $disk.FriendlyName } else { [string]$disk.DeviceId }
                    PredictFailure = [bool]($disk.HealthStatus -ne 'Healthy')
                    Source = 'Get-PhysicalDisk'
                }
            }
        }
        catch {
        }
    }

    if ($entries.Count -eq 0) {
        Write-Host 'No SMART data available via native providers.' -ForegroundColor Yellow
        Write-Host 'Tip: Use CrystalDiskInfo for vendor-specific details.' -ForegroundColor Yellow
        return
    }

    foreach ($entry in $entries) {
        $state = if ($entry.PredictFailure) { 'Critical' } else { 'OK' }
        $text = if ($entry.PredictFailure) { 'PredictFailure=TRUE' } else { 'PredictFailure=FALSE' }
        Write-Status -label $entry.Disk -value ('{0} ({1})' -f $text, $entry.Source) -state $state
    }
}

function Start-BsodAnalysis {
    [CmdletBinding()]
    param()

    try {
        $toolPath = Ensure-ToolInstalled -name 'BlueScreenView'
        Start-Process -FilePath $toolPath
    }
    catch {
        Write-Log -level 'ERROR' -message ("BSOD analysis failed: {0}" -f $_.Exception.Message)
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function Repair-WindowsUpdate {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Repairing Windows Update components.'

    $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    foreach ($svc in $services) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }

    Rename-Item -Path "$env:SystemRoot\SoftwareDistribution" -NewName ('SoftwareDistribution.bak.{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')) -ErrorAction SilentlyContinue
    Rename-Item -Path "$env:SystemRoot\System32\catroot2" -NewName ('catroot2.bak.{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')) -ErrorAction SilentlyContinue

    foreach ($svc in $services) {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }

    Write-Host 'Windows Update components reset complete.' -ForegroundColor Green
}

function Restart-WindowsUpdateServices {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Restarting Windows Update related services.'
    foreach ($svc in @('wuauserv', 'bits', 'cryptsvc', 'msiserver')) {
        Restart-Service -Name $svc -ErrorAction SilentlyContinue
    }
    Write-Host 'Windows Update services restarted.' -ForegroundColor Green
}

function Invoke-WinPulseTempCleanup {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Running WinPulse temp artifact cleanup.'

    foreach ($pattern in @('WinPulse-*', 'WinPulse_Bootstrap-*')) {
        Get-ChildItem -Path $env:TEMP -Filter $pattern -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    foreach ($pattern in @('office-config-*.xml', 'disk-stress-*.tmp')) {
        Get-ChildItem -Path $script:WinPulsePaths.Exports -Filter $pattern -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $script:WinPulsePaths.Bin -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host 'WinPulse temp artifact cleanup complete.' -ForegroundColor Green
}

function Invoke-StoreAppRepair {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Running Store/AppX repair flow.'
    foreach ($processName in @('WinStore.App', 'WindowsTerminal', 'Widgets', 'WidgetService', 'StartMenuExperienceHost', 'SearchHost')) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Process -FilePath 'wsreset.exe' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue

    foreach ($serviceName in @('InstallService', 'ClipSVC', 'wuauserv', 'bits')) {
        Restart-Service -Name $serviceName -ErrorAction SilentlyContinue
    }
}

function Show-WinPulseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$plan
    )

    Write-Host ('Plan: {0}' -f $plan.Label) -ForegroundColor Cyan
    Write-Host ('Reason: {0}' -f $plan.Reason)
    Write-Host 'Steps:'
    foreach ($step in $plan.Steps) {
        Write-Host ('- {0}' -f $step)
    }
    Write-Host ''
}

function Show-WinPulseRepairDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$before,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$after
    )

    Write-Host 'Repair result (before -> after):' -ForegroundColor Cyan
    Write-Host ('- WU errors (24h): {0} -> {1}' -f $before.Health.WindowsUpdateErrorCount24Hours, $after.Health.WindowsUpdateErrorCount24Hours)
    Write-Host ('- Critical events (24h): {0} -> {1}' -f $before.Health.CriticalLast24Hours, $after.Health.CriticalLast24Hours)
    Write-Host ('- Pending reboot: {0} -> {1}' -f $before.Health.PendingReboot, $after.Health.PendingReboot)
    Write-Host ('- Internet: {0} -> {1}' -f $before.Network.Internet, $after.Network.Internet)
    Write-Host ''
}

function Invoke-WinPulseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pending_reboot', 'wu_services', 'store_apps', 'network_stack', 'wu_components', 'system_files', 'temp_cleanup')]
        [string]$planid,

        [switch]$dryrun
    )

    if ($dryrun) {
        return
    }

    switch ($planid) {
        'pending_reboot' {
            Write-Host '  Scheduling reboot in 30 seconds. Save your work now.' -ForegroundColor Yellow
            & shutdown.exe /r /t 30 /c "WinPulse: Executing pending reboot"
            Write-Host '  Reboot scheduled. The system will restart in 30 seconds.' -ForegroundColor Cyan
            Write-Host '  Run ''shutdown /a'' to abort.' -ForegroundColor Gray
        }
        'wu_services' {
            Restart-WindowsUpdateServices
        }
        'store_apps' {
            Invoke-StoreAppRepair
            Write-Host 'Store/AppX repair flow complete.' -ForegroundColor Green
        }
        'network_stack' {
            Repair-NetworkStack
        }
        'wu_components' {
            Repair-WindowsUpdate
        }
        'system_files' {
            Repair-SystemFiles
        }
        'temp_cleanup' {
            Invoke-WinPulseTempCleanup
        }
    }
}

function Invoke-WinPulseGuidedRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan,

        [Parameter(Mandatory = $true)]
        [string]$planid
    )

    $plans = @(Get-WinPulseRepairPlans -scan $scan)
    $plan = $plans | Where-Object { $_.Id -eq $planid } | Select-Object -First 1
    if (-not $plan) {
        Write-Host 'Repair plan is no longer applicable to current scan.' -ForegroundColor Yellow
        return $scan
    }

    Show-WinPulseRepairPlan -plan $plan
    $mode = Select-WinPulseMenuItem -Title ('Repair: {0}' -f $plan.Label) -Items @(
        @{ Label = 'Dry Run';      Key = 'D'; Hint = 'Show plan only' },
        @{ Label = 'Execute now';  Key = 'E'; Hint = 'Apply changes' },
        @{ Separator = $true },
        @{ Label = 'Cancel';       Key = 'C'; Color = 'DarkGray' }
    )
    if ($mode -eq 'C' -or -not $mode) { return $scan }

    if ($mode -eq 'D') {
        Invoke-WinPulseRepairPlan -planid $plan.Id -dryrun
        Write-Host 'Dry run complete. No changes were made.' -ForegroundColor Green
        return $scan
    }

    $confirm = Select-WinPulseMenuItem -Title ('Execute: {0}?' -f $plan.Label) -Items @(
        @{ Label = 'Yes, execute'; Key = 'Y'; Hint = 'Apply now' },
        @{ Separator = $true },
        @{ Label = 'No, cancel';   Key = 'N'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'Y') {
        Write-Host 'Repair cancelled.' -ForegroundColor Yellow
        return $scan
    }

    Invoke-WinPulseRepairPlan -planid $plan.Id
    if ($plan.Id -eq 'pending_reboot') {
        Wait-WinPulseKey '  Press any key to return to menu'
        return $scan
    }
    $after = Invoke-CoreScan
    Show-WinPulseRepairDelta -before $scan -after $after
    Show-WinPulseDashboard -scan $after
    return $after
}

function Repair-SystemFiles {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Running DISM and SFC.'
    Start-Process -FilePath 'dism.exe' -ArgumentList '/Online /Cleanup-Image /RestoreHealth' -Wait -NoNewWindow
    Start-Process -FilePath 'sfc.exe' -ArgumentList '/scannow' -Wait -NoNewWindow
    Write-Host 'SFC + DISM finished.' -ForegroundColor Green
}

function Wait-WinPulseKey {
    param([string]$Message = '  Press any key to continue')
    Write-Host $Message -ForegroundColor Gray -NoNewline
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { $null = Read-Host }
    Write-Host ''
}

function Invoke-WinGetInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$id
    )

    & winget install --id $id --accept-source-agreements --accept-package-agreements --silent
}

function Select-WinPulsePackageManager {
    # Returns 'winget', 'choco', 'ninite', or $null (cancelled)
    [CmdletBinding()]
    param()
    return Select-WinPulseMenuItem -Title 'Package Manager' -Items @(
        @{ Label = 'winget';      Key = 'W'; Hint = 'Windows Package Manager' },
        @{ Label = 'Chocolatey';  Key = 'C'; Hint = 'Community repo' },
        @{ Label = 'Ninite';      Key = 'N'; Hint = 'Web installer (browser)' },
        @{ Separator = $true },
        @{ Label = 'Back';        Key = 'B'; Color = 'DarkGray' }
    )
}

function Invoke-WinPulseInstallInWindow {
    # Installs packages via winget in a separate PowerShell window
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages,
        [switch]$dryrun
    )
    if ($dryrun) {
        foreach ($pkg in $packages) { Write-Host ('[DRY RUN] winget install --id {0}' -f $pkg.Id) -ForegroundColor Cyan }
        return
    }
    $lines = @("Write-Host 'WinPulse - winget install' -ForegroundColor Cyan; Write-Host ''")
    foreach ($pkg in $packages) {
        $locale = if ($pkg.Locale) { " --locale $($pkg.Locale)" } else { '' }
        $lines += "Write-Host 'Installing $($pkg.Name)...' -ForegroundColor White"
        $lines += "winget install --id '$($pkg.Id)' --accept-source-agreements --accept-package-agreements$locale"
    }
    $lines += "Write-Host ''; Write-Host 'Done. Press Enter to close.' -ForegroundColor Green; Read-Host"
    Start-Process powershell -ArgumentList @('-NoProfile', '-Command', ($lines -join '; ')) -Wait
}

function Invoke-WinPulseChocoInstallInWindow {
    # Installs packages via Chocolatey in a separate PowerShell window
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages,
        [switch]$dryrun
    )
    $pkgs = @($packages | Where-Object { $_.ChocoId })
    if ($pkgs.Count -eq 0) { Write-Host '  No Chocolatey IDs defined for selected packages.' -ForegroundColor Yellow; return }
    if ($dryrun) {
        foreach ($pkg in $pkgs) { Write-Host ('[DRY RUN] choco install {0} -y' -f $pkg.ChocoId) -ForegroundColor Cyan }
        return
    }
    $idList = ($pkgs.ChocoId) -join ' '
    $cmd = "Write-Host 'WinPulse - Chocolatey install' -ForegroundColor Cyan; Write-Host ''; choco install $idList -y --force; Write-Host ''; Write-Host 'Done. Press Enter to close.' -ForegroundColor Green; Read-Host"
    Start-Process powershell -ArgumentList @('-NoProfile', '-Command', $cmd) -Verb RunAs -Wait
}

function Get-WinPulseNiniteCatalog {
    # Full Ninite app catalog organized by categories (matching ninite.com)
    return @(
        # --- Browsers ---
        @{ Category = 'Browsers';     Label = 'Chrome';           Slug = 'chrome' },
        @{ Category = 'Browsers';     Label = 'Firefox';          Slug = 'firefox' },
        @{ Category = 'Browsers';     Label = 'Firefox ESR';      Slug = 'firefoxesr' },
        @{ Category = 'Browsers';     Label = 'Opera';            Slug = 'opera' },
        @{ Category = 'Browsers';     Label = 'Brave';            Slug = 'brave' },
        # --- Messaging ---
        @{ Category = 'Messaging';    Label = 'Zoom';             Slug = 'zoom' },
        @{ Category = 'Messaging';    Label = 'Teams';            Slug = 'teams' },
        @{ Category = 'Messaging';    Label = 'Discord';          Slug = 'discord' },
        @{ Category = 'Messaging';    Label = 'Skype';            Slug = 'skype' },
        @{ Category = 'Messaging';    Label = 'Telegram';         Slug = 'telegram' },
        @{ Category = 'Messaging';    Label = 'Signal';           Slug = 'signal' },
        # --- Media ---
        @{ Category = 'Media';        Label = 'VLC';              Slug = 'vlc' },
        @{ Category = 'Media';        Label = 'MPC-HC';           Slug = 'mpc' },
        @{ Category = 'Media';        Label = 'Spotify';          Slug = 'spotify' },
        @{ Category = 'Media';        Label = 'iTunes';           Slug = 'itunes' },
        @{ Category = 'Media';        Label = 'Kodi';             Slug = 'kodi' },
        @{ Category = 'Media';        Label = 'HandBrake';        Slug = 'handbrake' },
        @{ Category = 'Media';        Label = 'Audacity';         Slug = 'audacity' },
        @{ Category = 'Media';        Label = 'K-Lite Codecs';    Slug = 'klitecodecs' },
        @{ Category = 'Media';        Label = 'foobar2000';       Slug = 'foobar' },
        @{ Category = 'Media';        Label = 'AIMP';             Slug = 'aimp' },
        # --- Imaging ---
        @{ Category = 'Imaging';      Label = 'Paint.NET';        Slug = 'paint.net' },
        @{ Category = 'Imaging';      Label = 'GIMP';             Slug = 'gimp' },
        @{ Category = 'Imaging';      Label = 'IrfanView';        Slug = 'irfanview' },
        @{ Category = 'Imaging';      Label = 'IrfanView Plugins';Slug = 'irfanviewplugins' },
        @{ Category = 'Imaging';      Label = 'Krita';            Slug = 'krita' },
        @{ Category = 'Imaging';      Label = 'XnView';           Slug = 'xnview' },
        @{ Category = 'Imaging';      Label = 'Inkscape';         Slug = 'inkscape' },
        @{ Category = 'Imaging';      Label = 'ShareX';           Slug = 'sharex' },
        # --- Documents ---
        @{ Category = 'Documents';    Label = 'Adobe Reader DC';  Slug = 'reader' },
        @{ Category = 'Documents';    Label = 'SumatraPDF';       Slug = 'sumatrapdf' },
        @{ Category = 'Documents';    Label = 'LibreOffice';      Slug = 'libreoffice' },
        @{ Category = 'Documents';    Label = 'FoxitReader';      Slug = 'foxit' },
        @{ Category = 'Documents';    Label = 'Notepad++';        Slug = 'notepadplusplus' },
        # --- Security ---
        @{ Category = 'Security';     Label = 'Malwarebytes';     Slug = 'malwarebytes' },
        @{ Category = 'Security';     Label = 'Avast';            Slug = 'avast' },
        @{ Category = 'Security';     Label = 'AVG';              Slug = 'avg' },
        @{ Category = 'Security';     Label = 'Avira';            Slug = 'avira' },
        @{ Category = 'Security';     Label = 'Bitdefender Free'; Slug = 'bitdefender' },
        # --- Compression ---
        @{ Category = 'Compression';  Label = '7-Zip';            Slug = '7zip' },
        @{ Category = 'Compression';  Label = 'PeaZip';           Slug = 'peazip' },
        @{ Category = 'Compression';  Label = 'WinRAR';           Slug = 'winrar' },
        # --- Developer ---
        @{ Category = 'Developer';    Label = 'Python 3';         Slug = 'python' },
        @{ Category = 'Developer';    Label = 'Node.js';          Slug = 'nodejs' },
        @{ Category = 'Developer';    Label = 'VS Code';          Slug = 'vscode' },
        @{ Category = 'Developer';    Label = 'Git';              Slug = 'git' },
        @{ Category = 'Developer';    Label = 'Java (Adoptium)';  Slug = 'adoptopenjdk8' },
        @{ Category = 'Developer';    Label = 'Java 11';          Slug = 'adoptopenjdk11' },
        @{ Category = 'Developer';    Label = 'Java 17';          Slug = 'adoptopenjdk17' },
        @{ Category = 'Developer';    Label = 'PuTTY';            Slug = 'putty' },
        @{ Category = 'Developer';    Label = 'WinSCP';           Slug = 'winscp' },
        @{ Category = 'Developer';    Label = 'FileZilla';        Slug = 'filezilla' },
        # --- Utilities ---
        @{ Category = 'Utilities';    Label = 'TeamViewer';       Slug = 'teamviewer' },
        @{ Category = 'Utilities';    Label = 'AnyDesk';          Slug = 'anydesk' },
        @{ Category = 'Utilities';    Label = 'Greenshot';        Slug = 'greenshot' },
        @{ Category = 'Utilities';    Label = 'Everything';       Slug = 'everything' },
        @{ Category = 'Utilities';    Label = 'CrystalDiskInfo';  Slug = 'crystaldiskinfo' },
        @{ Category = 'Utilities';    Label = 'HWMonitor';        Slug = 'hwmonitor' },
        @{ Category = 'Utilities';    Label = 'Process Hacker';   Slug = 'processhacker' },
        @{ Category = 'Utilities';    Label = 'Speccy';           Slug = 'speccy' },
        @{ Category = 'Utilities';    Label = 'Recuva';           Slug = 'recuva' },
        @{ Category = 'Utilities';    Label = 'CCleaner';         Slug = 'ccleaner' },
        @{ Category = 'Utilities';    Label = 'Revo Uninstaller';  Slug = 'revo' },
        # --- Storage ---
        @{ Category = 'Storage';      Label = 'Dropbox';          Slug = 'dropbox' },
        @{ Category = 'Storage';      Label = 'Google Drive';     Slug = 'googledrive' },
        @{ Category = 'Storage';      Label = 'OneDrive';         Slug = 'onedrive' },
        # --- Remote ---
        @{ Category = 'Remote';       Label = 'LogMeIn';          Slug = 'logmein' },
        @{ Category = 'Remote';       Label = 'GoToMeeting';      Slug = 'gotomeeting' }
    )
}

function Show-WinPulseNiniteMenu {
    [CmdletBinding()]
    param()

    $catalog = @(Get-WinPulseNiniteCatalog)
    $categories = @($catalog | ForEach-Object { $_['Category'] } | Select-Object -Unique)

    # Step 1: pick categories to browse
    Clear-Host
    Write-WinPulseHeader -title 'Ninite - Categories'
    $categoryItems = @(foreach ($cat in $categories) {
        $count = @($catalog | Where-Object { $_['Category'] -eq $cat }).Count
        @{ Label = $cat; Key = $cat; Hint = ('{0} apps' -f $count) }
    })
    $pickedCategories = @(Select-WinPulseMultiMenuItem -Title 'Ninite - Select categories' -Items $categoryItems)
    if ($pickedCategories.Count -eq 0) { return }

    # Step 2: for each picked category, pick apps
    $selectedSlugs = @()
    foreach ($cat in $pickedCategories) {
        $appsInCat = @($catalog | Where-Object { $_['Category'] -eq $cat })
        if ($appsInCat.Count -eq 0) { continue }
        $appItems = @(foreach ($app in $appsInCat) {
            @{ Label = $app['Label']; Key = $app['Slug']; Hint = $app['Slug'] }
        })
        Clear-Host
        Write-WinPulseHeader -title ('Ninite - {0}' -f $cat)
        $picked = @(Select-WinPulseMultiMenuItem -Title ('{0} - Select apps' -f $cat) -Items $appItems)
        if ($picked.Count -gt 0) {
            $selectedSlugs += $picked
        }
    }

    $selectedSlugs = @($selectedSlugs | Select-Object -Unique)
    if ($selectedSlugs.Count -eq 0) { return }

    $slugStr = $selectedSlugs -join '-'
    $url = 'https://ninite.com/{0}/ninite.exe' -f $slugStr
    $dest = Join-Path $script:WinPulsePaths.Bin 'ninite-install.exe'

    Clear-Host
    Write-WinPulseHeader -title 'Ninite Install'
    Write-Host ('  Downloading Ninite installer ({0} apps)...' -f $selectedSlugs.Count) -ForegroundColor Yellow
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        Write-Host '  Running Ninite installer...' -ForegroundColor Yellow
        Start-Process -FilePath $dest -Wait
        Write-Host '  Ninite install complete.' -ForegroundColor Green
    } catch {
        Write-Host ('  Ninite download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    Wait-WinPulseKey
}

function Invoke-WinPulseNinite {
    # Downloads and runs Ninite installer for selected packages
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages
    )
    $slugs = @($packages | Where-Object { $_.NiniteSlug } | ForEach-Object { $_.NiniteSlug })
    if ($slugs.Count -eq 0) {
        Write-Host '  None of the selected packages are available on Ninite.' -ForegroundColor Yellow
        return
    }

    $missing = @($packages | Where-Object { -not $_.NiniteSlug } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0) {
        Write-Host ('  Skipped (not in Ninite): {0}' -f ($missing -join ', ')) -ForegroundColor Yellow
    }

    $url = 'https://ninite.com/{0}/ninite.exe' -f ($slugs -join '-')
    $dest = Join-Path $script:WinPulsePaths.Bin 'ninite-install.exe'
    Write-Host ('  Downloading Ninite installer ({0} apps)...' -f $slugs.Count) -ForegroundColor Yellow
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        Write-Host '  Running Ninite installer...' -ForegroundColor Yellow
        Start-Process -FilePath $dest -Wait
        Write-Host '  Ninite install complete.' -ForegroundColor Green
    } catch {
        Write-Host ('  Ninite download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Test-WinGetAvailable {
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) { return $false }
    # Verify EULA accepted and winget is functional
    try {
        $null = & winget list --accept-source-agreements 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Ensure-WinGet {
    # Returns $true if winget is ready to use
    [CmdletBinding()]
    param()
    if (Test-WinGetAvailable) { return $true }
    if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
        Write-Host '  winget not found. Install App Installer from the Microsoft Store.' -ForegroundColor Yellow
    } else {
        Write-Host '  winget found but not functional (EULA not accepted?).' -ForegroundColor Yellow
        Write-Host '  Run: winget list --accept-source-agreements' -ForegroundColor Gray
    }
    return $false
}

function Test-ChocolateyAvailable {
    [CmdletBinding()]
    param()
    # Check executable directly - Get-Command only sees PATH of current session
    $chocoBin = Join-Path $env:ProgramData 'chocolatey\bin'
    $chocoExe = Join-Path $chocoBin 'choco.exe'
    if (Test-Path -Path $chocoExe) {
        # Make sure it's in PATH for this session so subsequent choco calls work
        if ($env:PATH -notmatch [regex]::Escape($chocoBin)) {
            $env:PATH = $env:PATH + ';' + $chocoBin
        }
        return $true
    }
    return [bool](Get-Command -Name choco -ErrorAction SilentlyContinue)
}

function Ensure-Chocolatey {
    # Returns $true if choco is ready. Offers to install if missing.
    [CmdletBinding()]
    param()
    if (Test-ChocolateyAvailable) { return $true }
    $install = Select-WinPulseMenuItem -Title 'Chocolatey not installed' -Items @(
        @{ Label = 'Install Chocolatey now'; Key = 'I'; Hint = 'Opens new window' },
        @{ Separator = $true },
        @{ Label = 'Cancel'; Key = 'C'; Color = 'DarkGray' }
    )
    if ($install -ne 'I') { return $false }
    $cmd = "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')); Write-Host ''; Write-Host 'Chocolatey installed. Press Enter to close.' -ForegroundColor Green; Read-Host"
    Start-Process powershell -ArgumentList @('-NoProfile', '-Command', $cmd) -Verb RunAs -Wait
    # Refresh PATH in current session after install
    return (Test-ChocolateyAvailable)
}

function Show-WinPulseChocoMenu {
    # Chocolatey search -> select -> install flow
    [CmdletBinding()]
    param()

    Clear-Host
    Write-WinPulseHeader -title 'Chocolatey'
    if (-not (Ensure-Chocolatey)) {
        Write-Host '  Chocolatey not available.' -ForegroundColor Red
        Wait-WinPulseKey
        return
    }

    while ($true) {
        Clear-Host
        Write-WinPulseHeader -title 'Chocolatey'
        Write-Host '  Zadej nazev balicku (prazdne = zpet):' -ForegroundColor Yellow
        Write-Host -NoNewline '  > '
        [Console]::CursorVisible = $true
        $term = (Read-Host).Trim()
        [Console]::CursorVisible = $false
        if ($term -eq '') { return }

        Clear-Host
        Write-WinPulseHeader -title ('Chocolatey - hledam: {0}' -f $term)
        Write-Host '  Vyhledavam...' -ForegroundColor Gray

        $searchOutput = @()
        try {
            $searchOutput = @(& choco search $term --limit-output 2>&1 | Where-Object { $_ -match '^\S+\|' })
        }
        catch {
            Write-Host ('  Chyba pri vyhledavani: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Wait-WinPulseKey
            continue
        }

        if ($searchOutput.Count -eq 0) {
            Write-Host '  Zadne vysledky.' -ForegroundColor Yellow
            Wait-WinPulseKey
            continue
        }

        $pkgItems = @($searchOutput | ForEach-Object {
            $parts = $_ -split '\|'
            if ($parts.Count -ge 2) {
                @{ Label = $parts[0]; Key = $parts[0]; Hint = $parts[1] }
            }
        } | Where-Object { $_ })

        if ($pkgItems.Count -eq 0) {
            Write-Host '  Zadne vysledky.' -ForegroundColor Yellow
            Wait-WinPulseKey
            continue
        }

        $selected = @(Select-WinPulseMultiMenuItem -Title ('Chocolatey - vysledky: {0}' -f $term) -Items $pkgItems)
        if ($selected.Count -eq 0) { continue }

        $idList = $selected -join ' '
        $cmd = "Write-Host 'WinPulse - Chocolatey install' -ForegroundColor Cyan; Write-Host ''; choco install $idList -y --force; Write-Host ''; Write-Host 'Hotovo. Stiskni Enter pro zavreni.' -ForegroundColor Green; Read-Host"
        Start-Process powershell -ArgumentList @('-NoProfile', '-Command', $cmd) -Verb RunAs -Wait
        return
    }
}

function Get-WinPulsePackageCatalog {
    [CmdletBinding()]
    param()

    # Id = winget package ID; ChocoId = chocolatey ID; NiniteSlug = ninite.com slug (empty = not in Ninite)
    return @(
        [pscustomobject]@{ Name = '7-Zip';                Id = '7zip.7zip';                    ChocoId = '7zip';          NiniteSlug = '7zip';        Locale = $null;    Category = 'Tools';    InBasicSet = $true  }
        [pscustomobject]@{ Name = 'Google Chrome';         Id = 'Google.Chrome';                ChocoId = 'googlechrome';  NiniteSlug = 'chrome';      Locale = $null;    Category = 'Browser';  InBasicSet = $true  }
        [pscustomobject]@{ Name = 'Firefox (CZ)';          Id = 'Mozilla.Firefox';              ChocoId = 'firefox';       NiniteSlug = 'firefox';     Locale = 'cs-CZ';  Category = 'Browser';  InBasicSet = $false }
        [pscustomobject]@{ Name = 'VLC';                   Id = 'VideoLAN.VLC';                 ChocoId = 'vlc';           NiniteSlug = 'vlc';         Locale = $null;    Category = 'Media';    InBasicSet = $true  }
        [pscustomobject]@{ Name = 'Adobe Acrobat Reader';  Id = 'Adobe.Acrobat.Reader.64-bit';  ChocoId = 'adobereader';   NiniteSlug = 'reader';      Locale = $null;    Category = 'PDF';      InBasicSet = $true  }
        [pscustomobject]@{ Name = 'LibreOffice';           Id = 'TheDocumentFoundation.LibreOffice'; ChocoId = 'libreoffice'; NiniteSlug = 'libreoffice'; Locale = $null; Category = 'Office';   InBasicSet = $false }
        [pscustomobject]@{ Name = 'Microsoft Teams';       Id = 'Microsoft.Teams';              ChocoId = 'microsoft-teams'; NiniteSlug = '';           Locale = $null;    Category = 'Comm';     InBasicSet = $true  }
        [pscustomobject]@{ Name = 'TeamViewer';            Id = 'TeamViewer.TeamViewer';        ChocoId = 'teamviewer';    NiniteSlug = 'teamviewer';  Locale = $null;    Category = 'Remote';   InBasicSet = $false }
        [pscustomobject]@{ Name = 'Notepad++';             Id = 'Notepad++.Notepad++';          ChocoId = 'notepadplusplus'; NiniteSlug = 'notepadplusplus'; Locale = $null; Category = 'Tools'; InBasicSet = $false }
    )
}

function Test-WinPulsePackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$id
    )

    try {
        $output = (& winget list --id $id --accept-source-agreements 2>$null | Out-String)
        return ($output -match [regex]::Escape($id))
    }
    catch {
        return $false
    }
}

function Show-WinPulsePackageTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages
    )

    Write-Host ('{0,3}  {1,-26} {2,-34} {3,-10} {4}' -f '#', 'Name', 'Winget ID', 'Category', 'Installed') -ForegroundColor Yellow
    for ($i = 0; $i -lt $packages.Count; $i++) {
        $pkg = $packages[$i]
        $installed = if (Test-WinPulsePackageInstalled -id $pkg.Id) { 'Yes' } else { 'No' }
        Write-Host ('{0,3}  {1,-26} {2,-34} {3,-10} {4}' -f ($i + 1), $pkg.Name, $pkg.Id, $pkg.Category, $installed)
    }
}

function Read-WinPulseSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$max
    )

    $raw = Read-Host 'Select numbers (example: 1,3,5)'
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $indexes = @()
    foreach ($part in ($raw -split ',')) {
        $token = $part.Trim()
        $value = 0
        if ([int]::TryParse($token, [ref]$value)) {
            if ($value -ge 1 -and $value -le $max -and -not ($indexes -contains $value)) {
                $indexes += $value
            }
        }
    }

    return @($indexes)
}

function Invoke-WinPulsePackageInstall {
    # Prompts for package manager then installs in separate window
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages,
        [switch]$dryrun
    )

    if ($dryrun) {
        foreach ($pkg in $packages) { Write-Host ('[DRY RUN] {0} ({1})' -f $pkg.Name, $pkg.Id) -ForegroundColor Cyan }
        return
    }

    $pm = Select-WinPulsePackageManager
    switch ($pm) {
        'W' {
            if (-not (Ensure-WinGet)) { Wait-WinPulseKey; return }
            Invoke-WinPulseInstallInWindow -packages $packages
        }
        'C' {
            if (-not (Ensure-Chocolatey)) { Wait-WinPulseKey; return }
            Invoke-WinPulseChocoInstallInWindow -packages $packages
        }
        'N' { Invoke-WinPulseNinite -packages $packages }
        default { Write-Host '  Cancelled.' -ForegroundColor Yellow }
    }
}

function Invoke-WinPulsePackageUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages,

        [switch]$dryrun
    )

    foreach ($pkg in $packages) {
        if ($dryrun) {
            Write-Host ('[DRY RUN] Uninstall {0} ({1})' -f $pkg.Name, $pkg.Id) -ForegroundColor Cyan
            continue
        }

        Write-Host ('Uninstalling {0} ({1})' -f $pkg.Name, $pkg.Id) -ForegroundColor White
        Uninstall-Application -id $pkg.Id
    }
}

function Install-BasicITSet {
    [CmdletBinding()]
    param(
        [switch]$dryrun
    )

    $packages = @(Get-WinPulsePackageCatalog | Where-Object { $_.InBasicSet })
    Write-WinPulseHeader -title 'Basic IT Set Preview'
    Show-WinPulsePackageTable -packages $packages
    Write-Host ''

    if ($dryrun) {
        Invoke-WinPulsePackageInstall -packages $packages -dryrun
        return
    }

    $confirm = Select-WinPulseMenuItem -Title 'Install Basic IT Set?' -Items @(
        @{ Label = 'Install';  Key = 'I'; Hint = 'Select package manager' },
        @{ Separator = $true },
        @{ Label = 'Cancel';   Key = 'C'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'I') { return }

    Invoke-WinPulsePackageInstall -packages $packages
}

function Invoke-WinPulseCustomInstall {
    [CmdletBinding()]
    param([switch]$dryrun)

    $catalog = @(Get-WinPulsePackageCatalog)
    $menuItems = @($catalog | ForEach-Object { @{ Label = $_.Name; Key = $_.Id; Hint = $_.Category } })
    $selectedKeys = @(Select-WinPulseMultiMenuItem -Title 'Custom Install - Space to toggle, Enter to confirm' -Items $menuItems)
    if ($selectedKeys.Count -eq 0) { return }

    $selected = @($catalog | Where-Object { $selectedKeys -contains $_.Id })
    Invoke-WinPulsePackageInstall -packages $selected -dryrun:$dryrun
}

function Invoke-WinPulseCustomUninstall {
    [CmdletBinding()]
    param([switch]$dryrun)

    $catalog = @(Get-WinPulsePackageCatalog)
    Write-Host '  Checking installed packages...' -ForegroundColor Gray
    $installed = @($catalog | Where-Object { Test-WinPulsePackageInstalled -id $_.Id })

    if ($installed.Count -eq 0) {
        Write-Host '  No catalog packages currently installed.' -ForegroundColor Yellow
        return
    }

    $menuItems = @($installed | ForEach-Object { @{ Label = $_.Name; Key = $_.Id; Hint = $_.Category } })
    $selectedKeys = @(Select-WinPulseMultiMenuItem -Title 'Custom Uninstall - Space to toggle, Enter to confirm' -Items $menuItems)
    if ($selectedKeys.Count -eq 0) { return }

    $selected = @($installed | Where-Object { $selectedKeys -contains $_.Id })

    if (-not $dryrun) {
        $cmd = "Write-Host 'WinPulse - winget uninstall' -ForegroundColor Cyan; Write-Host ''"
        foreach ($pkg in $selected) {
            $cmd += "; Write-Host 'Uninstalling $($pkg.Name)...' -ForegroundColor White; winget uninstall --id '$($pkg.Id)' --silent"
        }
        $cmd += "; Write-Host ''; Write-Host 'Done. Press Enter to close.' -ForegroundColor Green; Read-Host"
        Start-Process powershell -ArgumentList @('-NoProfile', '-Command', $cmd) -Wait
    } else {
        foreach ($pkg in $selected) { Write-Host ('[DRY RUN] Uninstall {0} ({1})' -f $pkg.Name, $pkg.Id) -ForegroundColor Cyan }
    }
}

function Update-AllApplications {
    [CmdletBinding()]
    param()

    $cmd = "Write-Host 'WinPulse - winget upgrade --all' -ForegroundColor Cyan; Write-Host ''; winget upgrade --all --accept-source-agreements --accept-package-agreements; Write-Host ''; Write-Host 'Done. Press Enter to close.' -ForegroundColor Green; Read-Host"
    Start-Process powershell -ArgumentList @('-NoProfile', '-Command', $cmd) -Wait
}

function Uninstall-Application {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$id
    )

    & winget uninstall --id $id --silent
}

function Get-WinPulseOfficeCatalog {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Name = 'Office 2021 Home and Business (CZ)'; ProductId = 'HomeBusiness2021Retail'; Channel = $null;           Version = '2021'; Edition = 'HomeBusiness' }
        [pscustomobject]@{ Name = 'Office 2021 Home (CZ)';               ProductId = 'HomeStudent2021Retail';  Channel = $null;           Version = '2021'; Edition = 'Home' }
        [pscustomobject]@{ Name = 'Office 2021 Standard Volume (CZ)';    ProductId = 'Standard2021Volume';     Channel = 'PerpetualVL2021'; Version = '2021'; Edition = 'StandardVolume' }
        [pscustomobject]@{ Name = 'Office 2024 Home and Business (CZ)'; ProductId = 'HomeBusiness2024Retail'; Channel = $null;           Version = '2024'; Edition = 'HomeBusiness' }
        [pscustomobject]@{ Name = 'Office 2024 Home (CZ)';               ProductId = 'HomeStudent2024Retail';  Channel = $null;           Version = '2024'; Edition = 'Home' }
        [pscustomobject]@{ Name = 'Office 2024 Standard Volume (CZ)';    ProductId = 'Standard2024Volume';     Channel = 'PerpetualVL2024'; Version = '2024'; Edition = 'StandardVolume' }
        [pscustomobject]@{ Name = 'Microsoft 365 Home (CZ)';             ProductId = 'O365HomePremRetail';     Channel = 'Current';       Version = '365';  Edition = 'Home' }
        [pscustomobject]@{ Name = 'Microsoft 365 Business (CZ)';         ProductId = 'O365BusinessRetail';     Channel = 'Current';       Version = '365';  Edition = 'Business' }
    )
}

function Get-WinPulseOfficeSetupPath {
    [CmdletBinding()]
    param()

    $path = Join-Path $script:WinPulsePaths.Bin 'OfficeODT\setup.exe'
    if (Test-Path -Path $path) {
        return $path
    }
    return $null
}

function Ensure-WinPulseOfficeSetup {
    [CmdletBinding()]
    param()

    $setupPath = Get-WinPulseOfficeSetupPath
    if ($setupPath) {
        return $setupPath
    }

    $odtDir = Join-Path $script:WinPulsePaths.Bin 'OfficeODT'
    if (-not (Test-Path -Path $odtDir)) {
        New-Item -ItemType Directory -Path $odtDir -Force | Out-Null
    }

    # officecdn.microsoft.com/pr/wsus/setup.exe is the ODT setup.exe served directly (no redirect).
    $downloadUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
    $dest = Join-Path $odtDir 'setup.exe'

    Write-Host '  Downloading Office Deployment Tool...' -ForegroundColor Yellow
    Write-Log -level 'INFO' -message ('Downloading ODT setup.exe from {0}' -f $downloadUrl)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $downloadUrl -OutFile $dest -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw ('Failed to download Office Deployment Tool: {0}' -f $_.Exception.Message)
    }

    $setupPath = Get-WinPulseOfficeSetupPath
    if (-not $setupPath) {
        throw ('Office Deployment Tool setup.exe not found after download to {0}.' -f $odtDir)
    }

    return $setupPath
}

function Invoke-WinPulseOfficeConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$xmlcontent,

        [string]$description = 'Office operation'
    )

    $setupPath = Ensure-WinPulseOfficeSetup
    $xmlPath = Join-Path $script:WinPulsePaths.Exports ('office-config-{0}.xml' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -Path $xmlPath -Value $xmlcontent -Encoding UTF8

    Write-Host ("Starting: {0}" -f $description) -ForegroundColor Cyan
    Start-Process -FilePath $setupPath -ArgumentList ("/configure `"{0}`"" -f $xmlPath) -Wait -NoNewWindow
}

function Install-WinPulseOffice {
    [CmdletBinding()]
    param()

    $catalog = @(Get-WinPulseOfficeCatalog)

    Clear-Host
    Write-WinPulseHeader -title 'Office Install'
    $yearChoice = Select-WinPulseMenuItem -Title 'Office Install - Version' -Items @(
        @{ Label = 'Office 2021';     Key = '1'; Hint = 'Perpetual' },
        @{ Label = 'Office 2024';     Key = '4'; Hint = 'Perpetual' },
        @{ Label = 'Microsoft 365';   Key = '3'; Hint = 'Subscription' }
    )
    if (-not $yearChoice) { return }

    $yearMap = @{ '1' = '2021'; '4' = '2024'; '3' = '365' }
    $selectedYear = $yearMap[$yearChoice]
    $filtered = @($catalog | Where-Object { $_.Version -eq $selectedYear })

    $editionKeyMap = @{
        'HomeBusiness'   = @{ Key = 'H'; Hint = 'Word/Excel/Outlook/PP' }
        'Home'           = @{ Key = 'S'; Hint = 'Word/Excel/PP' }
        'StandardVolume' = @{ Key = 'V'; Hint = 'Volume license' }
        'Business'       = @{ Key = 'B'; Hint = 'Word/Excel/Outlook/PP/Teams' }
    }
    $editionItems = @(foreach ($item in $filtered) {
        $map = if ($editionKeyMap.ContainsKey($item.Edition)) { $editionKeyMap[$item.Edition] } else { @{ Key = $item.Edition[0]; Hint = $item.Edition } }
        @{ Label = $item.Name; Key = $map['Key']; Hint = $map['Hint'] }
    })
    Clear-Host
    Write-WinPulseHeader -title 'Office Install'
    $edKey = Select-WinPulseMenuItem -Title ('Office {0} - Edition' -f $selectedYear) -Items $editionItems
    if (-not $edKey) { return }

    $selection = $filtered | Where-Object {
        $map = if ($editionKeyMap.ContainsKey($_.Edition)) { $editionKeyMap[$_.Edition] } else { @{ Key = $_.Edition[0] } }
        $map['Key'] -eq $edKey
    } | Select-Object -First 1
    if (-not $selection) { return }

    $channelAttribute = if ($selection.Channel) { (' Channel="{0}"' -f $selection.Channel) } else { '' }
    $xml = @"
<Configuration>
  <Add OfficeClientEdition="64"$channelAttribute>
    <Product ID="$($selection.ProductId)">
      <Language ID="cs-cz" />
    </Product>
  </Add>
  <Display Level="Full" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@

    Clear-Host
    Write-WinPulseHeader -title 'Office Install'
    Write-Host ('  Selected: {0}' -f $selection.Name) -ForegroundColor Cyan
    Write-Host ('  Product ID: {0}' -f $selection.ProductId)
    if ($selection.Channel) {
        Write-Host ('  Channel: {0}' -f $selection.Channel)
    }
    Write-Host ''
    $confirm = Select-WinPulseMenuItem -Title 'Start Office install?' -Items @(
        @{ Label = 'Yes, install'; Key = 'Y'; Hint = 'Opens installer' },
        @{ Separator = $true },
        @{ Label = 'Cancel'; Key = 'C'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'Y') { return
    }

    Invoke-WinPulseOfficeConfiguration -xmlcontent $xml -description ('Office install - {0}' -f $selection.Name)
}

function Uninstall-WinPulseOffice {
    [CmdletBinding()]
    param()

    $xml = @"
<Configuration>
  <Remove All="TRUE"/>
  <Display Level="None" AcceptEULA="TRUE"/>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>
</Configuration>
"@

    Clear-Host
    Write-WinPulseHeader -title 'Office Uninstall'
    Write-Host '  Odstrani vsechny produkty Office (Click-to-Run). Tiche odstraneni.' -ForegroundColor Yellow
    Write-Host ''
    $confirm = Select-WinPulseMenuItem -Title 'Uninstall Office?' -Items @(
        @{ Label = 'Yes, uninstall'; Key = 'Y'; Hint = 'Removes all Office' },
        @{ Separator = $true },
        @{ Label = 'Cancel'; Key = 'C'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'Y') { return }

    Invoke-WinPulseOfficeConfiguration -xmlcontent $xml -description 'Office uninstall'
}

function Repair-WinPulseOffice {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-WinPulseHeader -title 'Office Repair'
    $c2rCandidates = @(
        (Join-Path $env:ProgramFiles 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe')
    )

    $client = $null
    foreach ($path in $c2rCandidates) {
        if ($path -and (Test-Path -Path $path)) {
            $client = $path
            break
        }
    }

    if ($client) {
        Write-Host 'Starting Office repair prompt...' -ForegroundColor Cyan
        Start-Process -FilePath $client -ArgumentList '/repairpromptuser' -Wait
        return
    }

    Write-Host 'Office repair client not found. Opening Programs and Features for manual repair.' -ForegroundColor Yellow
    Start-Process -FilePath 'control.exe' -ArgumentList 'appwiz.cpl'
}

function Show-WinPulseOfficeMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        Write-WinPulseHeader -title 'Office'
        $choice = Select-WinPulseMenuItem -Title 'Office' -Items @(
            @{ Label = 'Install Office';    Key = 'I'; Hint = 'Version/CZ' },
            @{ Label = 'Uninstall Office';  Key = 'U'; Hint = 'Silent remove' },
            @{ Label = 'Repair Office';     Key = 'R'; Hint = 'Fix install' }
        )
        switch ($choice) {
            'I' { try { Install-WinPulseOffice } catch { Write-Host ("  Office install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }; Wait-WinPulseKey }
            'U' { try { Uninstall-WinPulseOffice } catch { Write-Host ("  Office uninstall failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }; Wait-WinPulseKey }
            'R' { try { Repair-WinPulseOffice } catch { Write-Host ("  Office repair failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }; Wait-WinPulseKey }
            default { return }
        }
    }
}

function Reinstall-Office {
    [CmdletBinding()]
    param()

    Show-WinPulseOfficeMenu
}

function New-WinPulseRestorePoint {
    [CmdletBinding()]
    param(
        [string]$description = 'WinPulse pre-tweak checkpoint'
    )

    Checkpoint-Computer -Description $description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
}

function Backup-WinPulseRegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$keypath
    )

    $safeName = ($keypath -replace '[\\/:*?"<>|]', '_')
    $target = Join-Path $script:WinPulsePaths.Backups ("{0}-{1}.reg" -f $safeName, (Get-Date -Format 'yyyyMMddHHmmss'))
    & reg.exe export $keypath $target /y | Out-Null
    return $target
}

function Set-WinPulseTweak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DisableCopilot', 'DisableWebSearch', 'DisableTelemetryPolicy')]
        [string]$name,

        [switch]$revert
    )

    New-WinPulseRestorePoint

    switch ($name) {
        'DisableCopilot' {
            Backup-WinPulseRegistryKey -keypath 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' | Out-Null
            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
            $value = if ($revert) { 0 } else { 1 }
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type DWord -Value $value
        }
        'DisableWebSearch' {
            Backup-WinPulseRegistryKey -keypath 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' | Out-Null
            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force | Out-Null
            $value = if ($revert) { 1 } else { 0 }
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'DisableWebSearch' -Type DWord -Value (1 - $value)
        }
        'DisableTelemetryPolicy' {
            Backup-WinPulseRegistryKey -keypath 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' | Out-Null
            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force | Out-Null
            $value = if ($revert) { 3 } else { 0 }
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type DWord -Value $value
        }
    }
}

function Remove-CommonBloatware {
    [CmdletBinding()]
    param()

    $apps = @('Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameCallableUI', 'Microsoft.YourPhone', 'Microsoft.ZuneMusic')
    foreach ($app in $apps) {
        Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
    }
}

function Invoke-NetworkDiagnostic {
    [CmdletBinding()]
    param()

    $profile = Get-NetIPConfiguration | Select-Object -First 1
    return [pscustomobject]@{
        Adapter = $profile.InterfaceAlias
        IPv4 = if ($profile.IPv4Address) { $profile.IPv4Address.IPAddress } else { $null }
        Gateway = if ($profile.IPv4DefaultGateway) { $profile.IPv4DefaultGateway.NextHop } else { $null }
        DnsServers = if ($profile.DNSServer) { $profile.DNSServer.ServerAddresses } else { @() }
        Internet = (Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }
}

function Clear-NetworkDns {
    [CmdletBinding()]
    param()

    & ipconfig /flushdns | Out-Null
}

function Reset-NetworkTcpIp {
    [CmdletBinding()]
    param()

    & netsh int ip reset | Out-Null
}

function Reset-NetworkWinsock {
    [CmdletBinding()]
    param()

    & netsh winsock reset | Out-Null
}

function Restart-NetworkAdapters {
    [CmdletBinding()]
    param()

    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        Disable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Enable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Repair-NetworkStack {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Running network stack repair.'
    Clear-NetworkDns
    Reset-NetworkTcpIp
    Reset-NetworkWinsock
    Restart-NetworkAdapters
    Write-Host 'Network repair completed. Reboot may be required.' -ForegroundColor Green
}

function Get-WinPulseSecurityAssessment {
    [CmdletBinding()]
    param()

    $localAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
    $avProducts = @(Get-WinPulseAntivirusProducts | Where-Object { $_ -and $_.PSObject.Properties['Name'] })
    $thirdPartyCount = @($avProducts | Where-Object { -not $_.IsMicrosoft }).Count
    $uac = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -ErrorAction SilentlyContinue
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    $bitlocker = Get-BitLockerVolume -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        LocalAdmins = $localAdmins
        AntivirusProducts = $avProducts
        AntivirusThirdPartyCount = $thirdPartyCount
        EffectiveRealtimeProtection = if ($thirdPartyCount -gt 0) { $true } elseif ($defender) { [bool]$defender.RealTimeProtectionEnabled } else { $false }
        DefenderRealTime = if ($defender) { [bool]$defender.RealTimeProtectionEnabled } else { $false }
        UacEnabled = if ($uac) { [bool]$uac.EnableLUA } else { $false }
        SecureBootEnabled = [bool]$secureBoot
        BitLocker = $bitlocker
    }
}

function Test-WeakServiceConfiguration {
    [CmdletBinding()]
    param()

    $suspicious = Get-CimInstance -ClassName Win32_Service | Where-Object {
        $_.StartName -match 'LocalSystem' -and $_.PathName -match ' ' -and $_.PathName -notmatch '^"'
    }

    return $suspicious | Select-Object Name, DisplayName, StartName, PathName
}

function Invoke-WinPulseLightCleanup {
    [CmdletBinding()]
    param()

    Get-ChildItem -Path $script:WinPulsePaths.Exports -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host 'Light cleanup completed.' -ForegroundColor Green
}

function Invoke-WinPulseFullArtifactCleanup {
    [CmdletBinding()]
    param()

    Write-Log -level 'INFO' -message 'Running full WinPulse artifact cleanup.'

    Invoke-WinPulseLightCleanup
    Invoke-WinPulseTempCleanup

    foreach ($path in @(
            $script:WinPulsePaths.Bin,
            $script:WinPulsePaths.Backups,
            $script:WinPulsePaths.Modules
        )) {
        if (-not (Test-Path -Path $path)) { continue }
        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Full WinPulse artifact cleanup completed.' -ForegroundColor Green
}

function Remove-WinPulseCompletely {
    [CmdletBinding()]
    param()

    $confirm = Select-WinPulseMenuItem -Title '!! Remove WinPulse folder completely !!' -Items @(
        @{ Label = 'YES - delete C:\ProgramData\WinPulse'; Key = 'Y'; Hint = 'Irreversible'; Color = 'Red' },
        @{ Separator = $true },
        @{ Label = 'Cancel'; Key = 'C'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'Y') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }

    Remove-Item -Path $script:WinPulsePaths.Root -Recurse -Force -ErrorAction Stop
    Write-Host 'WinPulse folder removed.' -ForegroundColor Green
}

function Invoke-WinPulseCpuStressTest {
    [CmdletBinding()]
    param(
        [int]$durationseconds = 60
    )

    Write-WinPulseHeader -title 'CPU Stress Test'
    Write-Host ('Duration: {0}s' -f $durationseconds)

    $workers = [math]::Max(1, [Environment]::ProcessorCount)
    $scriptBlock = {
        param([datetime]$until)
        while ((Get-Date) -lt $until) {
            $x = 0
            for ($i = 0; $i -lt 200000; $i++) {
                $x += [math]::Sqrt($i)
            }
        }
    }

    $until = (Get-Date).AddSeconds($durationseconds)
    $jobs = @()
    try {
        for ($i = 0; $i -lt $workers; $i++) {
            $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList $until
        }

        Write-Host ('Started {0} workers. Press Ctrl+C only if required.' -f $workers) -ForegroundColor Cyan
        while ((Get-Date) -lt $until) {
            Start-Sleep -Seconds 2
            $cpu = $null
            try {
                $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
                if ($perf -and $perf.PSObject.Properties['PercentProcessorTime']) {
                    $cpu = [double]$perf.PercentProcessorTime
                }
            }
            catch {
            }

            if ($null -ne $cpu) {
                Write-Host ('CPU: {0:N1}%' -f $cpu)
            }
            else {
                Write-Host 'CPU counter unavailable on this system.' -ForegroundColor Yellow
            }
        }

        $jobs | Wait-Job | Out-Null
        Write-Host 'CPU stress test complete.' -ForegroundColor Green
    }
    finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WinPulseDiskStressTest {
    [CmdletBinding()]
    param(
        [int]$sizemb = 512
    )

    Write-WinPulseHeader -title 'Disk Stress Test'
    $testFile = Join-Path $script:WinPulsePaths.Exports ('disk-stress-{0}.tmp' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $bytes = $sizemb * 1MB
    $buffer = New-Object byte[] (1MB)
    (New-Object Random).NextBytes($buffer)

    Write-Host ('Writing {0} MB test file...' -f $sizemb)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fs = [IO.File]::Open($testFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        for ($i = 0; $i -lt $sizemb; $i++) {
            $fs.Write($buffer, 0, $buffer.Length)
        }
    }
    finally {
        $fs.Dispose()
    }
    $sw.Stop()
    $writeMbps = ($bytes / 1MB) / [math]::Max(0.1, $sw.Elapsed.TotalSeconds)

    Write-Host ('Reading test file...' )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fs = [IO.File]::OpenRead($testFile)
    try {
        while ($fs.Read($buffer, 0, $buffer.Length) -gt 0) { }
    }
    finally {
        $fs.Dispose()
    }
    $sw.Stop()
    $readMbps = ($bytes / 1MB) / [math]::Max(0.1, $sw.Elapsed.TotalSeconds)

    Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
    Write-Host ('Write: {0:N1} MB/s | Read: {1:N1} MB/s' -f $writeMbps, $readMbps) -ForegroundColor Green
}

function Invoke-WinPulseRamQuickTest {
    [CmdletBinding()]
    param(
        [int]$durationseconds = 20
    )

    Write-WinPulseHeader -title 'RAM Quick Test'
    Write-Host ('Sampling RAM metrics for {0}s...' -f $durationseconds)
    $freeSamplesMB = @()
    $usedPercentSamples = @()
    $until = (Get-Date).AddSeconds($durationseconds)
    while ((Get-Date) -lt $until) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $totalMB = [double]$os.TotalVisibleMemorySize / 1024
            $freeMB = [double]$os.FreePhysicalMemory / 1024
            $usedPercent = if ($totalMB -gt 0) { (($totalMB - $freeMB) / $totalMB) * 100 } else { 0 }

            $freeSamplesMB += $freeMB
            $usedPercentSamples += $usedPercent
        }
        catch {
            Write-Host ('RAM sample failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            break
        }
        Start-Sleep -Seconds 2
    }

    if ($freeSamplesMB.Count -eq 0 -or $usedPercentSamples.Count -eq 0) {
        Write-Host 'RAM metrics unavailable on this system.' -ForegroundColor Yellow
        return
    }

    $avgAvail = ($freeSamplesMB | Measure-Object -Average).Average
    $minAvail = ($freeSamplesMB | Measure-Object -Minimum).Minimum
    $avgUsedPercent = ($usedPercentSamples | Measure-Object -Average).Average
    $maxUsedPercent = ($usedPercentSamples | Measure-Object -Maximum).Maximum

    Write-Host ('Average Free RAM: {0:N0} MB' -f $avgAvail)
    Write-Host ('Minimum Free RAM: {0:N0} MB' -f $minAvail)
    Write-Host ('Average RAM usage: {0:N1}%' -f $avgUsedPercent)
    Write-Host ('Peak RAM usage: {0:N1}%' -f $maxUsedPercent)
    Write-Host 'For full RAM diagnostics use Windows Memory Diagnostic (reboot required).' -ForegroundColor Yellow
}

function Start-WinPulseMemoryDiagnostic {
    [CmdletBinding()]
    param()

    Write-Host 'Windows Memory Diagnostic requires reboot.' -ForegroundColor Yellow
    $confirm = Select-WinPulseMenuItem -Title 'Memory Diagnostic (reboot required)' -Items @(
        @{ Label = 'Yes, reboot now'; Key = 'Y'; Hint = 'Runs on next boot' },
        @{ Separator = $true },
        @{ Label = 'Cancel'; Key = 'C'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'Y') { return
    }

    Start-Process -FilePath 'mdsched.exe'
}

function Start-WinPulseFurMarkAdvanced {
    [CmdletBinding()]
    param()

    Write-Host 'Warning: FurMark is aggressive GPU stress. Use only on non-production tests.' -ForegroundColor Yellow
    $confirm = Select-WinPulseMenuItem -Title 'Launch FurMark?' -Items @(
        @{ Label = 'Yes, launch'; Key = 'Y'; Hint = 'GPU stress test' },
        @{ Separator = $true },
        @{ Label = 'Cancel'; Key = 'C'; Color = 'DarkGray' }
    )
    if ($confirm -ne 'Y') { return
    }

    if (-not (Test-WinGetAvailable)) {
        Write-Host 'winget is required for temporary FurMark install/uninstall mode.' -ForegroundColor Red
        return
    }

    $hadBefore = $false
    $installedByWinPulse = $false
    $installedPackageId = $null
    $launchedNeedsManualWait = $false
    $packageCandidates = @('Geeks3D.FurMark.2', 'Geeks3D.FurMark', 'Geeks3D.FurMark.1')
    $lastInstallError = $null
    try {
        foreach ($pkg in $packageCandidates) {
            try {
                $listOutput = & winget list --id $pkg --exact 2>&1
                if (($listOutput | Out-String) -match [regex]::Escape($pkg)) {
                    $hadBefore = $true
                    $installedPackageId = $pkg
                    break
                }
            }
            catch {
            }
        }

        if (-not $hadBefore) {
            Write-Host 'Installing FurMark temporarily...' -ForegroundColor Cyan
            foreach ($pkg in $packageCandidates) {
                $installOutput = & winget install --id $pkg --exact --disable-interactivity --accept-source-agreements --accept-package-agreements --silent 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $installedByWinPulse = $true
                    $installedPackageId = $pkg
                    break
                }
                $lastInstallError = ($installOutput | Out-String).Trim()
            }
            if (-not $installedPackageId) {
                throw ("winget install failed for all FurMark package IDs. Last error: {0}" -f $lastInstallError)
            }
        }
        else {
            Write-Host ("Using existing FurMark package: {0}" -f $installedPackageId) -ForegroundColor Yellow
        }

        $candidates = @(
            (Join-Path $env:ProgramFiles 'Geeks3D\FurMark\FurMark_GUI.exe'),
            (Join-Path $env:ProgramFiles 'Geeks3D\FurMark2_x64\FurMark_GUI.exe'),
            (Join-Path $env:ProgramFiles 'Geeks3D\FurMark2\FurMark_GUI.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Geeks3D\FurMark\FurMark_GUI.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Geeks3D\FurMark2_x64\FurMark_GUI.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Geeks3D\FurMark2\FurMark_GUI.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Geeks3D\FurMark\FurMark_GUI.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Geeks3D\FurMark2\FurMark_GUI.exe')
        )
        $furmarkPath = $null
        foreach ($path in $candidates) {
            if ($path -and (Test-Path -Path $path)) {
                $furmarkPath = $path
                break
            }
        }

        if (-not $furmarkPath) {
            $wingetPackagesRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
            if (Test-Path -Path $wingetPackagesRoot) {
                $furmarkPath = (Get-ChildItem -Path $wingetPackagesRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -imatch '^Geeks3D\.FurMark(\.2)?_' } |
                    ForEach-Object {
                        Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Where-Object {
                                $_.Extension -ieq '.exe' -and
                                $_.Name -imatch '^FurMark_GUI.*\.exe$'
                            } |
                            Select-Object -First 1
                    } |
                    Select-Object -First 1 -ExpandProperty FullName)
            }
        }

        if (-not $furmarkPath) {
            $furmarkPath = (Get-ChildItem -Path @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension -ieq '.exe' -and
                    $_.Name -imatch '^FurMark_GUI.*\.exe$' -and
                    $_.FullName -imatch 'Geeks3D\\FurMark'
                } |
                Select-Object -First 1 -ExpandProperty FullName)
        }

        if ($furmarkPath) {
            Write-Host ("Launching: {0}" -f $furmarkPath) -ForegroundColor Cyan
            $proc = Start-Process -FilePath $furmarkPath -PassThru
            if ($proc) {
                Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
            }
        }
        else {
            # Refresh PATH so newly installed winget command aliases are available in current session.
            $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
            $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
            if ($machinePath -and $userPath) {
                $env:Path = "$machinePath;$userPath"
            }

            $furmarkCmd = Get-Command 'FurMark_GUI' -ErrorAction SilentlyContinue
            if ($furmarkCmd) {
                Write-Host 'Launching FurMark via command alias: FurMark_GUI' -ForegroundColor Cyan
                try {
                    $proc = Start-Process -FilePath 'FurMark_GUI' -PassThru
                    if ($proc) {
                        Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    }
                    $launchedNeedsManualWait = $false
                }
                catch {
                    $launchedNeedsManualWait = $true
                }
            }

            if ($furmarkCmd -and -not $launchedNeedsManualWait) {
                # already launched and waited above
            }
            else {
            $linkPath = (Get-ChildItem -Path @(
                    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
                    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
                ) -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ieq '.lnk' -and $_.Name -imatch 'FurMark' } |
                Select-Object -First 1 -ExpandProperty FullName)

            if ($linkPath) {
                Write-Host ("Launching Start Menu shortcut: {0}" -f $linkPath) -ForegroundColor Cyan
                Start-Process -FilePath $linkPath | Out-Null
                $launchedNeedsManualWait = $true
            }
            elseif (Start-WinPulseAppByName -namepattern 'FurMark') {
                Write-Host 'Launching FurMark via Start Apps/AppID.' -ForegroundColor Cyan
                $launchedNeedsManualWait = $true
            }
            else {
                throw 'FurMark executable/AppID was not found after installation.'
            }
            }
        }

        if ($launchedNeedsManualWait) {
            Wait-WinPulseKey 'Close FurMark when done, then press any key to continue cleanup'
        }

        Write-Host 'FurMark test flow complete.' -ForegroundColor Green
    }
    catch {
        Write-Host ('FurMark start failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        if ($installedPackageId) {
            Write-Host 'Uninstalling FurMark package...' -ForegroundColor Cyan
            try {
                $uninstallOutput = & winget uninstall --id $installedPackageId --exact --disable-interactivity --silent 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host ('FurMark uninstall warning: {0}' -f (($uninstallOutput | Out-String).Trim())) -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host ('FurMark uninstall warning: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }
}

function Start-WinPulseStressMyPC {
    [CmdletBinding()]
    param()

    try {
        $toolPath = Ensure-ToolInstalled -name 'StressMyPC'
        Start-Process -FilePath $toolPath
    }
    catch {
        Write-Host ('StressMyPC portable lookup failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Trying direct fallback download...' -ForegroundColor Cyan
        try {
            $targetDir = Join-Path $script:WinPulsePaths.Bin 'StressMyPC'
            if (-not (Test-Path -Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            }

            $zipPath = Join-Path $script:WinPulsePaths.Bin ('StressMyPC-fallback-{0}.zip' -f ([Guid]::NewGuid().ToString('N')))
            Invoke-WebRequest -Uri 'https://www.softwareok.com/Download/StressMyPC.zip' -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

            $exe = Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^StressMyPC.*\.exe$' } |
                Select-Object -First 1
            if (-not $exe) {
                throw 'StressMyPC executable not found in fallback package.'
            }

            Start-Process -FilePath $exe.FullName
        }
        catch {
            Write-Host ('StressMyPC start failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function Show-WinPulseStressMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Stress Tests' -Items @(
            @{ Label = 'CPU stress test';          Key = 'C'; Hint = '60 seconds' },
            @{ Label = 'Disk stress test';         Key = 'D'; Hint = '512MB' },
            @{ Label = 'RAM quick test';           Key = 'R'; Hint = '20 seconds' },
            @{ Label = 'Memory Diagnostic';        Key = 'M'; Hint = 'Reboot req.' },
            @{ Label = 'StressMyPC';               Key = 'S'; Hint = 'Portable' },
            @{ Label = 'FurMark';                  Key = 'F'; Hint = 'GPU stress' }
        )
        if (-not $choice) { return }
        switch ($choice) {
            'C' { Invoke-WinPulseCpuStressTest -durationseconds 60 }
            'D' { Invoke-WinPulseDiskStressTest -sizemb 512 }
            'R' { Invoke-WinPulseRamQuickTest -durationseconds 20 }
            'M' { Start-WinPulseMemoryDiagnostic }
            'S' { Start-WinPulseStressMyPC }
            'F' { Start-WinPulseFurMarkAdvanced }
            default { return }
        }
        Write-Host ''; Wait-WinPulseKey
    }
}

function Invoke-WinPulseDiagnostics {
    [CmdletBinding()]
    param()

    function Show-WinPulseDiagnosticsSystemProfile {
        [CmdletBinding()]
        param()

        $hostname = $env:COMPUTERNAME
        $model = 'Unknown'
        $cpu = 'Unknown'
        $osVersion = 'Unknown'
        $firmware = Get-WinPulseFirmwareMode
        $activation = 'Unknown'

        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs -and $cs.Model) { $model = [string]$cs.Model }
        }
        catch {
        }

        try {
            $cpuObj = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cpuObj -and $cpuObj.Name) { $cpu = ([string]$cpuObj.Name).Trim() }
        }
        catch {
        }

        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                $osVersion = '{0} ({1})' -f $os.Caption, $os.BuildNumber
            }
        }
        catch {
        }

        try {
            $windowsLicense = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and
                    $_.PartialProductKey
                } |
                Select-Object -First 1
            if ($windowsLicense) {
                if ([int]$windowsLicense.LicenseStatus -eq 1) {
                    $activation = 'Activated'
                }
                elseif ([int]$windowsLicense.LicenseStatus -eq 0) {
                    $activation = 'Unlicensed'
                }
                else {
                    $activation = ('Status {0}' -f [int]$windowsLicense.LicenseStatus)
                }
            }
        }
        catch {
        }

        Write-WinPulseHeader -title 'System Profile'
        Write-Host ('PC: {0} | Model: {1}' -f $hostname, $model) -ForegroundColor Cyan
        Write-Host ('CPU: {0}' -f $cpu) -ForegroundColor Cyan
        Write-Host ('Boot: {0}' -f $firmware) -ForegroundColor Cyan
        Write-Host ('Windows: {0}' -f $osVersion) -ForegroundColor Cyan
        Write-Host ('Activation: {0}' -f $activation) -ForegroundColor Cyan
    }

    function Show-WinPulseDiagnosticsExtendedProfile {
        [CmdletBinding()]
        param()

        $serial = 'Unknown'
        $domain = 'Unknown'
        $uptimeText = 'Unknown'
        $ramTotal = 'Unknown'
        $secureBoot = 'Unknown'

        try {
            $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
            if ($bios -and $bios.SerialNumber) { $serial = [string]$bios.SerialNumber }
        }
        catch {
        }

        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs) {
                if ([bool]$cs.PartOfDomain) {
                    $domain = ('Domain: {0}' -f [string]$cs.Domain)
                }
                else {
                    $domain = 'Workgroup'
                }
            }
        }
        catch {
        }

        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                $uptime = (Get-Date) - $os.LastBootUpTime
                $uptimeText = ('{0}d {1}h {2}m' -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes)
                $ramTotal = ConvertTo-ReadableSize -bytes ([double]$os.TotalVisibleMemorySize * 1KB)
            }
        }
        catch {
        }

        try {
            $secureBoot = Get-WinPulseSecureBootState -firmwaremode (Get-WinPulseFirmwareMode)
        }
        catch {
        }

        Write-Host ('Serial: {0}' -f $serial) -ForegroundColor Cyan
        Write-Host ('Join: {0}' -f $domain) -ForegroundColor Cyan
        Write-Host ('Uptime: {0}' -f $uptimeText) -ForegroundColor Cyan
        Write-Host ('RAM Total: {0}' -f $ramTotal) -ForegroundColor Cyan
        Write-Host ('SecureBoot: {0}' -f $secureBoot) -ForegroundColor Cyan
    }

    function Show-WinPulseEventLogStats {
        [CmdletBinding()]
        param(
            [int]$hourback = 24
        )

        $since = (Get-Date).AddHours(-1 * [math]::Abs($hourback))
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                    LogName   = @('System', 'Application')
                    Level     = @([int]1, [int]2)
                    StartTime = $since
                } -ErrorAction SilentlyContinue)

            if ($events.Count -eq 0) {
                Write-Host 'Event stats: no critical/error events in selected window.' -ForegroundColor Green
                return
            }

            $sysCount = @($events | Where-Object { $_.LogName -eq 'System' }).Count
            $appCount = @($events | Where-Object { $_.LogName -eq 'Application' }).Count
            $critCount = @($events | Where-Object { $_.LevelDisplayName -eq 'Critical' }).Count
            $errCount = @($events | Where-Object { $_.LevelDisplayName -eq 'Error' }).Count

            Write-Host ('Event stats: Total {0} | Critical {1} | Error {2} | System {3} | App {4}' -f $events.Count, $critCount, $errCount, $sysCount, $appCount) -ForegroundColor Cyan

            $topProviders = @($events | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3)
            if ($topProviders.Count -gt 0) {
                Write-Host 'Top event providers:' -ForegroundColor Yellow
                foreach ($provider in $topProviders) {
                    Write-Host ('- {0}: {1}' -f $provider.Name, $provider.Count) -ForegroundColor Gray
                }
            }
        }
        catch {
            Write-Host ('Event stats unavailable: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    function Show-WinPulseStorageInventory {
        [CmdletBinding()]
        param()

        try {
            $drives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)
            if ($drives.Count -eq 0) {
                Write-Host 'Storage inventory unavailable.' -ForegroundColor Yellow
                return
            }

            Write-Host 'Storage inventory:' -ForegroundColor Yellow
            foreach ($d in $drives) {
                $size = if ($d.Size) { ConvertTo-ReadableSize -bytes ([double]$d.Size) } else { 'Unknown' }
                $model = if ($d.Model) { [string]$d.Model } else { 'Unknown model' }
                $iface = if ($d.InterfaceType) { [string]$d.InterfaceType } else { 'Unknown IF' }
                $status = if ($d.Status) { [string]$d.Status } else { 'Unknown' }
                Write-Host ('- {0} | {1} | {2} | Status {3}' -f $model, $iface, $size, $status) -ForegroundColor Gray
            }
        }
        catch {
            Write-Host ('Storage inventory error: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    function Add-WinPulseDiagScore {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('OK', 'WARN', 'CRIT')]
            [string]$state,
            [Parameter(Mandatory = $true)]
            [hashtable]$score
        )

        $score[$state] = [int]$score[$state] + 1
    }

    function Get-WinPulseLogHealthState {
        [CmdletBinding()]
        param(
            [int]$hourback = 24
        )

        try {
            $since = (Get-Date).AddHours(-1 * [math]::Abs($hourback))
            $events = @(Get-WinEvent -FilterHashtable @{
                    LogName   = @('System', 'Application')
                    Level     = @([int]1, [int]2)
                    StartTime = $since
                } -ErrorAction SilentlyContinue)

            if ($events.Count -eq 0) { return 'OK' }
            if ($events.Count -ge 25) { return 'CRIT' }
            return 'WARN'
        }
        catch {
            return 'WARN'
        }
    }

    function Get-WinPulseSmartHealthState {
        [CmdletBinding()]
        param()

        try {
            $smartStatus = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue)
            if ($smartStatus.Count -gt 0) {
                foreach ($item in $smartStatus) {
                    if ([bool]$item.PredictFailure) { return 'CRIT' }
                }
                return 'OK'
            }

            $physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
            if ($physical.Count -gt 0) {
                foreach ($disk in $physical) {
                    if ([string]$disk.HealthStatus -ne 'Healthy') { return 'CRIT' }
                }
                return 'OK'
            }
        }
        catch {
            return 'WARN'
        }

        return 'WARN'
    }

    function Get-WinPulseDiskSpaceHealthState {
        [CmdletBinding()]
        param()

        try {
            $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)
            if ($drives.Count -eq 0) { return 'WARN' }

            $hasWarn = $false
            foreach ($drive in $drives) {
                $size = [double]$drive.Size
                $free = [double]$drive.FreeSpace
                if ($size -le 0) { continue }
                $freePct = ($free / $size) * 100
                if ($freePct -lt 10) { return 'CRIT' }
                if ($freePct -lt 20) { $hasWarn = $true }
            }

            if ($hasWarn) { return 'WARN' }
            return 'OK'
        }
        catch {
            return 'WARN'
        }
    }

    function Get-WinPulseRamPressureHealthState {
        [CmdletBinding()]
        param()

        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if (-not $os) { return 'WARN' }

            $total = [double]$os.TotalVisibleMemorySize
            $free = [double]$os.FreePhysicalMemory
            if ($total -le 0) { return 'WARN' }

            $usedPct = ((($total - $free) / $total) * 100)
            if ($usedPct -ge 90) { return 'CRIT' }
            if ($usedPct -ge 80) { return 'WARN' }
            return 'OK'
        }
        catch {
            return 'WARN'
        }
    }

    function Show-WinPulseDiskFreeSpaceSummary {
        [CmdletBinding()]
        param()

        $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        if (-not $drives) {
            Write-Host 'Disk usage data unavailable.' -ForegroundColor Yellow
            return
        }

        foreach ($drive in $drives | Sort-Object DeviceID) {
            $size = [double]$drive.Size
            $free = [double]$drive.FreeSpace
            if ($size -le 0) { continue }

            $freePct = [math]::Round(($free / $size) * 100, 2)
            $usedPct = [math]::Round(100 - $freePct, 2)
            $freeReadable = ConvertTo-ReadableSize -bytes $free
            $sizeReadable = ConvertTo-ReadableSize -bytes $size

            $state = 'OK'
            $color = 'Green'
            if ($freePct -lt 10) {
                $state = 'CRIT'
                $color = 'Red'
            }
            elseif ($freePct -lt 20) {
                $state = 'WARN'
                $color = 'Yellow'
            }

            Write-Host ('[{0}] {1} free {2}% ({3}/{4}) | used {5}%' -f $state, $drive.DeviceID, $freePct, $freeReadable, $sizeReadable, $usedPct) -ForegroundColor $color
        }
    }

    function Invoke-WinPulseUnifiedDiagnostics {
        [CmdletBinding()]
        param()

        $score = @{ OK = 0; WARN = 0; CRIT = 0 }

        Write-WinPulseHeader -title 'Diagnostics'
        Write-Host 'Step 1/6: System profile...' -ForegroundColor Cyan
        Show-WinPulseDiagnosticsSystemProfile
        Show-WinPulseDiagnosticsExtendedProfile
        Add-WinPulseDiagScore -state 'OK' -score $score
        Write-Host ''

        Write-Host 'Step 2/6: Inspect logs (24h)...' -ForegroundColor Cyan
        Show-WinPulseEventLogStats -hourback 24
        Show-WinPulseEventLogInspection -hourback 24 -maxitems 15
        Add-WinPulseDiagScore -state (Get-WinPulseLogHealthState -hourback 24) -score $score
        Write-Host ''

        Write-Host 'Step 3/6: SMART summary...' -ForegroundColor Cyan
        Show-WinPulseSmartSummary
        Show-WinPulseStorageInventory
        Add-WinPulseDiagScore -state (Get-WinPulseSmartHealthState) -score $score
        Write-Host ''

        Write-Host 'Step 4/6: Disk free space check...' -ForegroundColor Cyan
        Show-WinPulseDiskFreeSpaceSummary
        Add-WinPulseDiagScore -state (Get-WinPulseDiskSpaceHealthState) -score $score
        Write-Host ''

        Write-Host 'Step 5/6: RAM quick test (10s)...' -ForegroundColor Cyan
        try {
            Invoke-WinPulseRamQuickTest -durationseconds 10
            Add-WinPulseDiagScore -state (Get-WinPulseRamPressureHealthState) -score $score
        }
        catch {
            Write-Host ('RAM quick test failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Add-WinPulseDiagScore -state 'WARN' -score $score
        }
        Write-Host ''

        Write-Host 'Step 6/6: Disk stress test (512MB)...' -ForegroundColor Cyan
        try {
            Invoke-WinPulseDiskStressTest -sizemb 512
            Add-WinPulseDiagScore -state 'OK' -score $score
        }
        catch {
            Write-Host ('Disk stress test failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Add-WinPulseDiagScore -state 'WARN' -score $score
        }
        Write-Host ''

        $pendingReboot = Test-WinPulsePendingReboot
        if ($pendingReboot) {
            Write-Host 'Reboot pending detected: YES' -ForegroundColor Yellow
            Add-WinPulseDiagScore -state 'WARN' -score $score
        }
        else {
            Write-Host 'Reboot pending detected: NO' -ForegroundColor Green
            Add-WinPulseDiagScore -state 'OK' -score $score
        }
        Write-Host 'For full offline RAM diagnostics schedule: mdsched.exe' -ForegroundColor Yellow

        Write-Host ''
        Write-WinPulseHeader -title 'Diagnostics Summary'
        Write-Host ('OK: {0} | WARN: {1} | CRIT: {2}' -f $score.OK, $score.WARN, $score.CRIT) -ForegroundColor Cyan
        Write-Host 'Diagnostics complete.' -ForegroundColor Green
    }

    Clear-Host
    Invoke-WinPulseUnifiedDiagnostics
    Write-Host ''
    Wait-WinPulseKey
}

function Show-WinPulseToolsMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'External Tools' -Items @(
            @{ Label = 'Autoruns';              Key = 'A'; Hint = 'Startup items' },
            @{ Label = 'OpenHardwareMonitor';   Key = 'H'; Hint = 'Temps/voltages' },
            @{ Label = 'BlueScreenView';        Key = 'B'; Hint = 'BSOD analysis' },
            @{ Label = 'CrystalDiskInfo';       Key = 'C'; Hint = 'Disk SMART' },
            @{ Label = 'StressMyPC';            Key = 'S'; Hint = 'Stress test' },
            @{ Label = 'FurMark';               Key = 'F'; Hint = 'GPU stress' },
            @{ Label = 'TechToolStore';         Key = 'T'; Hint = 'Tool suite' },
            @{ Label = 'O&O ShutUp10++';        Key = 'O'; Hint = 'Privacy' },
            @{ Label = 'Process Explorer';      Key = 'I'; Hint = 'Sysinternals' }
        )
        if (-not $choice) { return }
        switch ($choice) {
            'A' { Start-WinPulseAutoruns }
            'H' { Start-WinPulseOpenHardwareMonitor }
            'B' { Start-WinPulseBlueScreenView }
            'C' { Start-DeepDiskAnalysis }
            'S' { Start-WinPulseStressMyPC }
            'F' { Start-WinPulseFurMarkAdvanced }
            'T' { Start-WinPulseTechToolStore }
            'O' { Start-WinPulseOOShutUp }
            'I' { Start-WinPulseSysinternalsSuite }
            default { return }
        }
        Write-Host ''; Wait-WinPulseKey
    }
}

function Invoke-WinPulseRepairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Repairs (Guided)' -Items @(
            @{ Label = 'Windows Update errors';  Key = 'W'; Hint = 'Last 24h' },
            @{ Label = 'Detected repair plans';   Key = 'P'; Hint = 'Auto-detect' },
            @{ Label = 'Safe actions';             Key = 'S'; Hint = 'DISM/SFC/CHKDSK' }
        )
        if (-not $choice) { return $scan }
        switch ($choice) {
            'W' {
                $latestScan = Invoke-CoreScan
                Show-WindowsUpdateErrorDetails -scan $latestScan
                $scan = $latestScan
                Wait-WinPulseKey
            }
            'P' {
                $plans = @(Get-WinPulseRepairPlans -scan $scan)
                if ($plans.Count -eq 0) {
                    Write-Host '  No repair plans detected for current state.' -ForegroundColor Green
                    Wait-WinPulseKey
                    continue
                }

                $keys = '1234567890ABCDEFGHIJ'
                $planItems = @(for ($i = 0; $i -lt [math]::Min($plans.Count, $keys.Length); $i++) {
                    @{ Label = $plans[$i].Label; Key = [string]$keys[$i]; Hint = $plans[$i].Reason }
                })
                $planKey = Select-WinPulseMenuItem -Title 'Detected Repair Plans' -Items $planItems
                if (-not $planKey) { continue }

                $planIndex = $keys.IndexOf($planKey)
                $selected = if ($planIndex -ge 0) { $plans | Select-Object -Index $planIndex -ErrorAction SilentlyContinue } else { $null }
                if (-not $selected) {
                    continue
                }

                $scan = Invoke-WinPulseGuidedRepair -scan $scan -planid $selected.Id
            }
            'S' { $scan = Show-WinPulseSafeActions -scan $scan }
            default { return $scan }
        }
    }
}

function Show-WinPulseInstallMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Install / Apps' -Items @(
            @{ Label = 'Ninite catalog';          Key = 'N'; Hint = 'Direct download' },
            @{ Label = 'Chocolatey catalog';      Key = 'H'; Hint = 'Search & install' },
            @{ Label = 'Preview Basic IT Set';    Key = 'P'; Hint = 'Show list' },
            @{ Label = 'Install Basic IT Set';    Key = 'B'; Hint = 'Auto-install' },
            @{ Label = 'Custom install';          Key = 'C'; Hint = 'Multi-select' },
            @{ Label = 'Custom uninstall';        Key = 'U'; Hint = 'Multi-select' },
            @{ Label = 'Update all apps';         Key = 'A'; Hint = 'winget upgrade' },
            @{ Label = 'Office menu';             Key = 'O'; Hint = 'Install/repair' },
            @{ Separator = $true },
            @{ Label = 'Dry run: Basic IT';       Key = 'D'; Hint = 'Preview only'; Color = 'DarkGray' },
            @{ Label = 'Dry run: Install';        Key = 'I'; Hint = 'Preview only'; Color = 'DarkGray' },
            @{ Label = 'Dry run: Uninstall';      Key = 'X'; Hint = 'Preview only'; Color = 'DarkGray' }
        )
        if (-not $choice) { return }
        switch ($choice) {
            'N' { Show-WinPulseNiniteMenu }
            'H' { Show-WinPulseChocoMenu }
            'P' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                $preview = @(Get-WinPulsePackageCatalog | Where-Object { $_.InBasicSet })
                Write-WinPulseHeader -title 'Basic IT Set Preview'; Show-WinPulsePackageTable -packages $preview; Wait-WinPulseKey
            }
            'B' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Install-BasicITSet
            }
            'C' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Invoke-WinPulseCustomInstall
            }
            'U' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Invoke-WinPulseCustomUninstall
            }
            'A' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Update-AllApplications
            }
            'O' { Show-WinPulseOfficeMenu }
            'D' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Install-BasicITSet -dryrun; Wait-WinPulseKey
            }
            'I' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Invoke-WinPulseCustomInstall -dryrun; Wait-WinPulseKey
            }
            'X' {
                if (-not (Test-WinGetAvailable)) { Write-Host '  Winget not available.' -ForegroundColor Red; Wait-WinPulseKey; break }
                Invoke-WinPulseCustomUninstall -dryrun; Wait-WinPulseKey
            }
            default { return }
        }
    }
}

function Show-WinPulseTweaksMenu {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-WinPulseHeader -title 'Tweaks'
    Write-Host '  Tweaks are intentionally disabled for now.' -ForegroundColor Yellow
    Write-Host '  Planned: curated safe tweaks with clear revert support.' -ForegroundColor Yellow
    Write-Host ''
    Wait-WinPulseKey
}

function Show-WinPulseNetworkMenu {
    [CmdletBinding()]
    param()

    $choice = Select-WinPulseMenuItem -Title 'Network' -Items @(
        @{ Label = 'Full diagnostic';      Key = 'D'; Hint = 'All checks' },
        @{ Label = 'Flush DNS';            Key = 'F'; Hint = 'Clear cache' },
        @{ Label = 'Reset TCP/IP';         Key = 'T'; Hint = 'Stack reset' },
        @{ Label = 'Reset Winsock';        Key = 'W'; Hint = 'Socket reset' },
        @{ Label = 'Restart adapters';     Key = 'A'; Hint = 'Re-enable' },
        @{ Label = 'Repair network';       Key = 'R'; Hint = 'Auto-fix' }
    )
    switch ($choice) {
        'D' { Invoke-NetworkDiagnostic | Format-List | Out-Host }
        'F' { Clear-NetworkDns }
        'T' { Reset-NetworkTcpIp }
        'W' { Reset-NetworkWinsock }
        'A' { Restart-NetworkAdapters }
        'R' { Repair-NetworkStack }
        default { }
    }
}

function Show-WinPulseSecurityMenu {
    [CmdletBinding()]
    param()

    $choice = Select-WinPulseMenuItem -Title 'Security' -Items @(
        @{ Label = 'Security assessment';     Key = 'A'; Hint = 'Full check' },
        @{ Label = 'Weak service configs';    Key = 'W'; Hint = 'Permissions' },
        @{ Label = 'BitLocker status';        Key = 'B'; Hint = 'Encryption' }
    )
    switch ($choice) {
        'A' { Get-WinPulseSecurityAssessment | Format-List | Out-Host }
        'W' { Test-WeakServiceConfiguration | Format-Table -AutoSize | Out-Host }
        'B' { Get-BitLockerVolume | Format-Table MountPoint,ProtectionStatus,VolumeStatus -AutoSize | Out-Host }
        default { }
    }
}

function Show-WinPulseCleanupMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Cleanup' -Items @(
            @{ Label = 'Full artifact cleanup';   Key = 'A'; Hint = 'Data/cache' },
            @{ Label = 'Light cleanup';            Key = 'L'; Hint = 'Exports only' },
            @{ Label = 'Remove WinPulse folder';   Key = 'F'; Hint = 'Complete'; Color = 'DarkYellow' }
        )
        if (-not $choice) { return }
        switch ($choice) {
            'A' { Invoke-WinPulseFullArtifactCleanup; Wait-WinPulseKey }
            'L' { Invoke-WinPulseLightCleanup; Wait-WinPulseKey }
            'F' { Remove-WinPulseCompletely; Wait-WinPulseKey }
            default { return }
        }
    }
}

function Invoke-WinPulseExitCleanupPrompt {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host 'Exit cleanup: running full WinPulse cleanup and removing C:\ProgramData\WinPulse...' -ForegroundColor Cyan
    Invoke-WinPulseFullArtifactCleanup
    try {
        if (Test-Path -Path $script:WinPulsePaths.Root) {
            Remove-Item -Path $script:WinPulsePaths.Root -Recurse -Force -ErrorAction Stop
        }
        Write-Host 'WinPulse root folder removed.' -ForegroundColor Green
    }
    catch {
        Write-Host ('WinPulse root folder removal warning: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Show-WinPulseExportMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    # Exports include the detail-only sections, which are deferred at startup.
    $scan = Complete-WinPulseDetailScan -scan $scan

    while ($true) {
        $choice = Select-WinPulseMenuItem -Title 'Export' -Items @(
            @{ Label = 'Export Scan JSON';    Key = 'J'; Hint = '.json' },
            @{ Label = 'Export HTML Report';  Key = 'H'; Hint = '.html' },
            @{ Label = 'Export Bundle ZIP';   Key = 'B'; Hint = 'latest folder' }
        )
        if (-not $choice) { return }
        switch ($choice) {
            'J' {
                $target = Join-Path $script:WinPulsePaths.Exports ('scan-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $scan | ConvertTo-Json -Depth 6 | Set-Content -Path $target -Encoding UTF8
                Write-Host ("  Exported: {0}" -f $target) -ForegroundColor Green
                Wait-WinPulseKey
            }
            'H' {
                Export-WinPulseHtmlReport -scan $scan
                Wait-WinPulseKey
            }
            'B' {
                try { Export-WinPulseLatestBundle | Out-Null }
                catch { Write-Host ("  Export bundle failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
                Wait-WinPulseKey
            }
            default { return }
        }
    }
}

function Show-WinPulseMigrationMenu {
    # Groups all migration actions under one entry. Loops until Back/Esc.
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Migration' -Items @(
            @{ Label = 'Preflight (read-only report)'; Key = 'P'; Hint = 'Inspect & plan' },
            @{ Label = 'Backup (copy user data out)';  Key = 'B'; Hint = 'To a folder/drive' },
            @{ Label = 'Restore (put data back)';      Key = 'R'; Hint = 'From a backup' },
            @{ Label = 'Verify (re-check a backup)';   Key = 'V'; Hint = 'Integrity check' },
            @{ Label = 'Reinstall apps';                Key = 'A'; Hint = 'winget from backup' },
            @{ Separator = $true },
            @{ Label = 'Back';                         Key = 'Q'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'P' { Invoke-WinPulseMigrationPreflight | Out-Null; Wait-WinPulseKey }
            'B' { Invoke-WinPulseMigrationBackup | Out-Null; Wait-WinPulseKey }
            'R' { Invoke-WinPulseMigrationRestore | Out-Null; Wait-WinPulseKey }
            'V' { Invoke-WinPulseMigrationVerify | Out-Null; Wait-WinPulseKey }
            'A' { Invoke-WinPulseMigrationAppReinstall | Out-Null; Wait-WinPulseKey }
            default { return }
        }
    }
}

function Show-WinPulseMainMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        Show-WinPulseDashboard -scan $scan
        $choice = Select-WinPulseMenuItem -Title 'Main Menu' -Items @(
            @{ Label = 'Diagnostics';      Key = 'D'; Hint = 'System health' },
            @{ Label = 'W11 readiness';     Key = 'A'; Hint = 'Upgrade signals' },
            @{ Label = 'Migration';         Key = 'M'; Hint = 'Preflight/backup/restore/verify' },
            @{ Label = 'Install / Apps';    Key = 'I'; Hint = 'Packages' },
            @{ Label = 'Repairs (Guided)';  Key = 'R'; Hint = 'Fix issues' },
            @{ Label = 'External Tools';    Key = 'T'; Hint = 'Portable apps' },
            @{ Label = 'Cleanup';           Key = 'C'; Hint = 'Remove files' },
            @{ Label = 'Export';            Key = 'X'; Hint = 'JSON / HTML' },
            @{ Separator = $true },
            @{ Label = 'Exit';              Key = 'E'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'D' { Invoke-WinPulseDiagnostics; Write-Host ''; Wait-WinPulseKey }
            'A' { Show-WinPulseWindows11Readiness; Wait-WinPulseKey }
            'M' { Show-WinPulseMigrationMenu }
            'I' { Show-WinPulseInstallMenu }
            'R' { $scan = Invoke-WinPulseRepairs -scan $scan }
            'T' { Show-WinPulseToolsMenu }
            'C' { Show-WinPulseCleanupMenu }
            'X' { Show-WinPulseExportMenu -scan $scan }
            'E' { Invoke-WinPulseExitCleanupPrompt; return }
            default { }
        }
    }
}

function Show-WinPulseFindingsDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    Clear-Host
    Write-WinPulseHeader -title 'Findings & Details'

    # -- Problematic drivers --------------------------------------------------
    if ($scan.Drivers -and $scan.Drivers.Problematic.Count -gt 0) {
        Write-Host '  Problematic drivers:' -ForegroundColor Yellow
        foreach ($d in $scan.Drivers.Problematic) {
            Write-Host ('    {0}  [{1}]' -f $d['DeviceName'], $d['ErrorDescription']) -ForegroundColor Yellow
        }
        Write-Host ''
    }

    # -- Failed auto-start services -------------------------------------------
    if ($scan.Startup -and $scan.Startup.FailedAutoServices.Count -gt 0) {
        Write-Host '  Failed auto-start services:' -ForegroundColor Yellow
        foreach ($s in $scan.Startup.FailedAutoServices) {
            Write-Host ('    {0}  ({1})' -f $s['DisplayName'], $s['Name']) -ForegroundColor Yellow
        }
        Write-Host ''
    }

    # -- Stuck print jobs -----------------------------------------------------
    if ($scan.Printers -and $scan.Printers.StuckJobs.Count -gt 0) {
        Write-Host '  Stuck print jobs:' -ForegroundColor Yellow
        foreach ($j in $scan.Printers.StuckJobs) {
            Write-Host ('    {0}  doc: {1}  status: {2}  submitted: {3}' -f $j['PrinterName'], $j['DocumentName'], $j['JobStatus'], $j['SubmittedTime']) -ForegroundColor Yellow
        }
        Write-Host ''
    }

    # -- Other findings -------------------------------------------------------
    $otherFindings = @(Get-WinPulseTriageFindings -scan $scan | Where-Object {
        $msg = $_.Message
        -not ($msg -match '^Problematic device drivers') -and
        -not ($msg -match '^Failed auto-start services') -and
        -not ($msg -match '^Print jobs stuck')
    })
    if ($otherFindings.Count -gt 0) {
        Write-Host '  Other findings:' -ForegroundColor Yellow
        foreach ($f in $otherFindings) {
            $color = if ($f.Severity -eq 'Critical') { 'Red' } else { 'Yellow' }
            Write-Host ('    [{0}] {1}' -f $f.Severity.ToUpperInvariant(), $f.Message) -ForegroundColor $color
        }
        Write-Host ''
    }

    if ($scan.Drivers.Problematic.Count -eq 0 -and $scan.Startup.FailedAutoServices.Count -eq 0 -and
        $scan.Printers.StuckJobs.Count -eq 0 -and $otherFindings.Count -eq 0) {
        Write-Host '  No issues detected.' -ForegroundColor Green
        Write-Host ''
    }

    # -- Scan errors ----------------------------------------------------------
    if ($scan.Errors.Count -gt 0) {
        Write-Host '  Scan errors:' -ForegroundColor Yellow
        foreach ($e in $scan.Errors) {
            Write-Host ('    {0}' -f $e) -ForegroundColor Yellow
        }
        Write-Host ''
    }

    # -- System details -------------------------------------------------------
    Write-Host '  System Details:' -ForegroundColor Yellow
    Write-Host ('    Hostname : {0}' -f $scan.System.Hostname) -ForegroundColor White
    Write-Host ('    OS       : {0}' -f $scan.System.WindowsVersion) -ForegroundColor White
    Write-Host ('    Uptime   : {0}' -f $scan.System.Uptime) -ForegroundColor White
    if ($scan.HardwareDetail) {
        $cpuFull = if ($scan.HardwareDetail.CPU.Model -ne 'N/A') { ($scan.HardwareDetail.CPU.Model -replace '\s*(CPU|Processor|\(R\)|\(TM\)|@\s*[\d.]+GHz)\s*', ' ').Trim() -replace '\s+', ' ' } else { 'N/A' }
        $tpmLabel = if ($scan.TPM) { 'TPM {0}' -f $scan.TPM.Version } else { 'N/A' }
        $ramType = if ($scan.HardwareDetail.DIMMs.Count -gt 0) { $scan.HardwareDetail.DIMMs[0].Type } else { 'N/A' }
        Write-Host ('    CPU      : {0}' -f $cpuFull) -ForegroundColor White
        Write-Host ('    RAM type : {0}' -f $ramType) -ForegroundColor White
        Write-Host ('    TPM      : {0}' -f $tpmLabel) -ForegroundColor White
        if ($scan.HardwareDetail.Battery.Present) {
            $batHp = $scan.HardwareDetail.Battery.HealthPercent
            $batColor = if ($batHp -and $batHp -lt 50) { 'Yellow' } else { 'White' }
            $batLine = if ($batHp) { '    Battery  : {0}% health' -f $batHp } else { '    Battery  : present (wear data unavailable)' }
            Write-Host $batLine -ForegroundColor $batColor
        }
    }

    Write-Host ''
    Wait-WinPulseKey
}

function Show-WinPulseTriageMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        Show-WinPulseDashboard -scan $scan
        $choice = Select-WinPulseMenuItem -Title 'Quick Triage' -Items @(
            @{ Label = 'Findings & Details'; Key = 'F'; Hint = 'Full list + HW info' },
            @{ Label = 'W11 readiness';      Key = 'A'; Hint = 'Upgrade signals' },
            @{ Label = 'Migration';          Key = 'P'; Hint = 'Preflight/backup/restore/verify' },
            @{ Label = 'Full menu';          Key = 'M'; Hint = 'All options' },
            @{ Label = 'Re-scan';            Key = 'R'; Hint = 'Refresh data' },
            @{ Label = 'Inspect logs';       Key = 'L'; Hint = 'Last 24h' },
            @{ Label = 'Safe actions';       Key = 'S'; Hint = 'DISM/SFC/CHKDSK' },
            @{ Separator = $true },
            @{ Label = 'Exit';               Key = 'E'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'R' { $scan = Invoke-CoreScan }
            'F' { Show-WinPulseFindingsDetail -scan $scan }
            'A' { Show-WinPulseWindows11Readiness; Wait-WinPulseKey }
            'P' { Show-WinPulseMigrationMenu }
            'L' { Clear-Host; Show-WinPulseEventLogInspection -hourback 24 -maxitems 12; Write-Host ''; Wait-WinPulseKey }
            'S' { $scan = Show-WinPulseSafeActions -scan $scan }
            'M' { Show-WinPulseMainMenu -scan $scan; return }
            'E' { Invoke-WinPulseExitCleanupPrompt; return }
            default { }
        }
    }
}

function Show-WinPulseSafeActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Safe Actions' -Items @(
            @{ Label = 'Run DISM + SFC';          Key = 'S'; Hint = 'Repair files' },
            @{ Label = 'Run CHKDSK C: /scan';     Key = 'C'; Hint = 'Disk check' },
            @{ Label = 'Restart WU services';      Key = 'W'; Hint = 'Update svc' },
            @{ Label = 'Re-scan now';              Key = 'R'; Hint = 'Refresh' }
        )
        if (-not $choice) { return $scan }
        switch ($choice) {
            'S' { Repair-SystemFiles; $scan = Invoke-CoreScan; Wait-WinPulseKey }
            'C' { Start-Process -FilePath 'chkdsk.exe' -ArgumentList 'C:', '/scan' -Wait -NoNewWindow; $scan = Invoke-CoreScan; Wait-WinPulseKey }
            'W' { Restart-WindowsUpdateServices; $scan = Invoke-CoreScan; Wait-WinPulseKey }
            'R' { $scan = Invoke-CoreScan; Wait-WinPulseKey '  Re-scan complete. Press any key' }
            default { return $scan }
        }
    }
}

function Invoke-WinPulseMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Triage', 'Repair', 'W11Readiness', 'MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'ExportBundle')]
        [string]$mode,

        [string[]]$BackupUsers = @(),
        [string[]]$BackupFolders = @(),
        [string[]]$BackupApps = @(),
        [string]$BackupDestination = $null,
        [switch]$BackupExecute,
        [switch]$BackupIncludePrivateKeys,
        [switch]$BackupIncludeAppData,
        [switch]$BackupHashSample,
        [switch]$SkipBackupAppList,
        [string]$BackupProfilesRoot = $null,

        [string]$RestoreBackupPath = $null,
        [string]$RestoreRoot = $null,
        [string[]]$RestoreFolders = @(),
        [switch]$RestoreExecute,
        [switch]$RestoreHashSample,
        [string]$RestoreAsUser = $null,

        [string]$VerifyBackupPath = $null,

        [string]$AppsBackupPath = $null,
        [switch]$AppsExecute,
        [string[]]$AppsSelect = @()
    )

    switch ($mode) {
        'Triage' {
            Clear-Host
            Write-Host ('WinPulse build: {0}' -f $script:WinPulseVersion) -ForegroundColor Gray
            Write-Host ''
            Write-Host '  Loading system information...' -ForegroundColor Gray

            Write-Log -level 'INFO' -message ('WinPulse {0} starting core scan.' -f $script:WinPulseVersion)
            $scan = Invoke-CoreScan
            Show-WinPulseTriageMenu -scan $scan
        }
        'Repair' {
            Clear-Host
            Write-Host ('WinPulse build: {0}' -f $script:WinPulseVersion) -ForegroundColor Gray
            Write-Host ''
            Write-Host '  Loading system information...' -ForegroundColor Gray

            Write-Log -level 'INFO' -message ('WinPulse {0} starting repair-mode scan.' -f $script:WinPulseVersion)
            $scan = Invoke-CoreScan
            Invoke-WinPulseRepairs -scan $scan | Out-Null
        }
        'W11Readiness' {
            Write-Log -level 'INFO' -message ('WinPulse {0} running Windows 11 readiness mode.' -f $script:WinPulseVersion)
            Show-WinPulseWindows11Readiness
        }
        'MigrationPreflight' {
            Write-Log -level 'INFO' -message ('WinPulse {0} running migration preflight mode.' -f $script:WinPulseVersion)
            Invoke-WinPulseMigrationPreflight | Out-Null
        }
        'MigrationBackup' {
            Write-Log -level 'INFO' -message ('WinPulse {0} running migration backup mode.' -f $script:WinPulseVersion)
            Invoke-WinPulseMigrationBackup -BackupUsers $BackupUsers -BackupFolders $BackupFolders -BackupApps $BackupApps -BackupDestination $BackupDestination -BackupExecute:$BackupExecute -BackupIncludePrivateKeys:$BackupIncludePrivateKeys -BackupIncludeAppData:$BackupIncludeAppData -BackupHashSample:$BackupHashSample -SkipBackupAppList:$SkipBackupAppList -BackupProfilesRoot $BackupProfilesRoot | Out-Null
        }
        'MigrationRestore' {
            Write-Log -level 'INFO' -message ('WinPulse {0} running migration restore mode.' -f $script:WinPulseVersion)
            Invoke-WinPulseMigrationRestore -RestoreBackupPath $RestoreBackupPath -RestoreRoot $RestoreRoot -RestoreFolders $RestoreFolders -RestoreExecute:$RestoreExecute -RestoreHashSample:$RestoreHashSample -RestoreAsUser $RestoreAsUser | Out-Null
        }
        'MigrationVerify' {
            Invoke-WinPulseMigrationVerify -VerifyBackupPath $VerifyBackupPath | Out-Null
        }
        'MigrationApps' {
            Invoke-WinPulseMigrationAppReinstall -AppsBackupPath $AppsBackupPath -AppsExecute:$AppsExecute -AppsSelect $AppsSelect | Out-Null
        }
        'ExportBundle' {
            Write-Log -level 'INFO' -message ('WinPulse {0} running export bundle mode.' -f $script:WinPulseVersion)
            try {
                Export-WinPulseLatestBundle | Out-Null
            }
            catch {
                Write-Host ('Export bundle failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
                throw
            }
        }
    }
}

# Best-effort process scope bypass for locked defaults.
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
}
catch {
}

$bootstrapPath = $null
if (Get-Variable -Name PSCommandPath -ErrorAction SilentlyContinue) {
    $bootstrapPath = $PSCommandPath
}

$bootstrapDefinition = $null
if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.PSObject.Properties['Definition']) {
    $bootstrapDefinition = [string]$MyInvocation.MyCommand.Definition
}

function ConvertTo-WinPulseCommandArgument {
    [CmdletBinding()]
    param(
        [string]$value
    )

    return ('"{0}"' -f (([string]$value) -replace '"', '`"'))
}

function Test-WinPulsePathUnderRoot {
    [CmdletBinding()]
    param(
        [string]$path,
        [string]$root
    )

    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($root)) {
        return $false
    }

    try {
        $fullPath = ([System.IO.Path]::GetFullPath($path)).TrimEnd('\')
        $fullRoot = ([System.IO.Path]::GetFullPath($root)).TrimEnd('\')
        $rootPrefix = '{0}\' -f $fullRoot
        return ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase))
    }
    catch {
        return $false
    }
}

$elevationPassthrough = @()
if ($PSBoundParameters.ContainsKey('BackupUsers')) {
    foreach ($value in @($BackupUsers)) { $elevationPassthrough += @('-BackupUsers', (ConvertTo-WinPulseCommandArgument -value $value)) }
}
if ($PSBoundParameters.ContainsKey('BackupFolders')) {
    foreach ($value in @($BackupFolders)) { $elevationPassthrough += @('-BackupFolders', (ConvertTo-WinPulseCommandArgument -value $value)) }
}
if ($PSBoundParameters.ContainsKey('BackupApps')) {
    $backupAppsArgument = (ConvertTo-WinPulseBackupAppKeys -appKeys $BackupApps) -join ','
    if (-not [string]::IsNullOrWhiteSpace($backupAppsArgument)) {
        $elevationPassthrough += @('-BackupApps', (ConvertTo-WinPulseCommandArgument -value $backupAppsArgument))
    }
}
if ($PSBoundParameters.ContainsKey('BackupDestination')) { $elevationPassthrough += @('-BackupDestination', (ConvertTo-WinPulseCommandArgument -value $BackupDestination)) }
if ($BackupExecute) { $elevationPassthrough += '-BackupExecute' }
if ($BackupIncludePrivateKeys) { $elevationPassthrough += '-BackupIncludePrivateKeys' }
if ($BackupIncludeAppData) { $elevationPassthrough += '-BackupIncludeAppData' }
if ($BackupHashSample) { $elevationPassthrough += '-BackupHashSample' }
if ($SkipBackupAppList) { $elevationPassthrough += '-SkipBackupAppList' }
if ($PSBoundParameters.ContainsKey('BackupProfilesRoot')) { $elevationPassthrough += @('-BackupProfilesRoot', (ConvertTo-WinPulseCommandArgument -value $BackupProfilesRoot)) }
if ($PSBoundParameters.ContainsKey('RestoreBackupPath')) { $elevationPassthrough += @('-RestoreBackupPath', (ConvertTo-WinPulseCommandArgument -value $RestoreBackupPath)) }
if ($PSBoundParameters.ContainsKey('RestoreRoot')) { $elevationPassthrough += @('-RestoreRoot', (ConvertTo-WinPulseCommandArgument -value $RestoreRoot)) }
if ($PSBoundParameters.ContainsKey('RestoreFolders')) {
    foreach ($value in @($RestoreFolders)) { $elevationPassthrough += @('-RestoreFolders', (ConvertTo-WinPulseCommandArgument -value $value)) }
}
if ($RestoreExecute) { $elevationPassthrough += '-RestoreExecute' }
if ($RestoreHashSample) { $elevationPassthrough += '-RestoreHashSample' }
if ($PSBoundParameters.ContainsKey('RestoreAsUser')) { $elevationPassthrough += @('-RestoreAsUser', (ConvertTo-WinPulseCommandArgument -value $RestoreAsUser)) }
if ($PSBoundParameters.ContainsKey('VerifyBackupPath')) { $elevationPassthrough += @('-VerifyBackupPath', (ConvertTo-WinPulseCommandArgument -value $VerifyBackupPath)) }
if ($PSBoundParameters.ContainsKey('AppsBackupPath')) { $elevationPassthrough += @('-AppsBackupPath', (ConvertTo-WinPulseCommandArgument -value $AppsBackupPath)) }
if ($AppsExecute) { $elevationPassthrough += '-AppsExecute' }
if ($PSBoundParameters.ContainsKey('AppsSelect')) {
    $appsSelectArgument = (ConvertTo-WinPulseStringList -values $AppsSelect) -join ','
    if (-not [string]::IsNullOrWhiteSpace($appsSelectArgument)) {
        $elevationPassthrough += @('-AppsSelect', (ConvertTo-WinPulseCommandArgument -value $appsSelectArgument))
    }
}

$backupNonInteractiveForElevation = (
    $Mode -eq 'MigrationBackup' -and
    @($BackupUsers).Count -gt 0 -and
    (@($BackupFolders).Count -gt 0 -or @($BackupApps).Count -gt 0) -and
    -not [string]::IsNullOrWhiteSpace($BackupDestination)
)
$restoreNonInteractiveForElevation = (
    $Mode -eq 'MigrationRestore' -and
    -not [string]::IsNullOrWhiteSpace($RestoreBackupPath) -and
    -not [string]::IsNullOrWhiteSpace($RestoreRoot)
)
$verifyNonInteractiveForElevation = (
    $Mode -eq 'MigrationVerify' -and
    -not [string]::IsNullOrWhiteSpace($VerifyBackupPath)
)
$appsNonInteractiveForElevation = (
    $Mode -eq 'MigrationApps' -and
    -not [string]::IsNullOrWhiteSpace($AppsBackupPath)
)
$skipElevationForFixture = $false
$perUserTempRoot = [IO.Path]::GetTempPath()
if ($backupNonInteractiveForElevation -and -not [string]::IsNullOrWhiteSpace($BackupProfilesRoot)) {
    $skipElevationForFixture = (
        (Test-WinPulsePathUnderRoot -path $BackupProfilesRoot -root $perUserTempRoot) -and
        (Test-WinPulsePathUnderRoot -path $BackupDestination -root $perUserTempRoot)
    )
}
if ($restoreNonInteractiveForElevation -and -not [string]::IsNullOrWhiteSpace($RestoreRoot)) {
    $skipElevationForFixture = $skipElevationForFixture -or (
        (Test-WinPulsePathUnderRoot -path $RestoreBackupPath -root $perUserTempRoot) -and
        (Test-WinPulsePathUnderRoot -path $RestoreRoot -root $perUserTempRoot)
    )
}
if ($verifyNonInteractiveForElevation) {
    $skipElevationForFixture = $skipElevationForFixture -or (Test-WinPulsePathUnderRoot -path $VerifyBackupPath -root $perUserTempRoot)
}
if ($appsNonInteractiveForElevation -and -not $AppsExecute) {
    $skipElevationForFixture = $skipElevationForFixture -or (Test-WinPulsePathUnderRoot -path $AppsBackupPath -root $perUserTempRoot)
}

if ($skipElevationForFixture) {
    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulse'
    $script:WinPulsePaths.Root = $tempRoot
    $script:WinPulsePaths.Bin = Join-Path -Path $tempRoot -ChildPath 'bin'
    $script:WinPulsePaths.Logs = Join-Path -Path $tempRoot -ChildPath 'logs'
    $script:WinPulsePaths.Exports = Join-Path -Path $tempRoot -ChildPath 'exports'
    $script:WinPulsePaths.Backups = Join-Path -Path $tempRoot -ChildPath 'backups'
    $script:WinPulsePaths.Modules = Join-Path -Path $tempRoot -ChildPath 'modules'
}

Start-WinPulseElevation -bootstrappath $bootstrapPath -bootstrapdefinition $bootstrapDefinition -bootstrapurl 'https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1' -mode $Mode -passthrougharguments $elevationPassthrough -skipElevation:$skipElevationForFixture
if ($Mode -ne 'MigrationVerify') {
    Initialize-WinPulse
}

Invoke-WinPulseMode -mode $Mode -BackupUsers $BackupUsers -BackupFolders $BackupFolders -BackupApps $BackupApps -BackupDestination $BackupDestination -BackupExecute:$BackupExecute -BackupIncludePrivateKeys:$BackupIncludePrivateKeys -BackupIncludeAppData:$BackupIncludeAppData -BackupHashSample:$BackupHashSample -SkipBackupAppList:$SkipBackupAppList -BackupProfilesRoot $BackupProfilesRoot -RestoreBackupPath $RestoreBackupPath -RestoreRoot $RestoreRoot -RestoreFolders $RestoreFolders -RestoreExecute:$RestoreExecute -RestoreHashSample:$RestoreHashSample -RestoreAsUser $RestoreAsUser -VerifyBackupPath $VerifyBackupPath -AppsBackupPath $AppsBackupPath -AppsExecute:$AppsExecute -AppsSelect $AppsSelect
