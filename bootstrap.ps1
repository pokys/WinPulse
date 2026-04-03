#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        [string]$bootstrapurl
    )

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

# ── Extended Diagnostic Helpers ──────────────────────────────────────────────

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
            if (-not $entry.DisplayName) { continue }
            $key = '{0}|{1}' -f $entry.DisplayName, $entry.DisplayVersion
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $items += [ordered]@{
                Name        = $entry.DisplayName
                Version     = if ($entry.DisplayVersion) { $entry.DisplayVersion } else { 'N/A' }
                Publisher   = if ($entry.Publisher) { $entry.Publisher } else { 'N/A' }
                InstallDate = if ($entry.InstallDate) { $entry.InstallDate } else { 'N/A' }
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
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction SilentlyContinue |
            Where-Object { $_.PartialProductKey -and $_.Name -like '*Windows*' } |
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
        Errors      = @()
    }

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
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $totalMemory = [double]$os.TotalVisibleMemorySize * 1KB
        $freeMemory = [double]$os.FreePhysicalMemory * 1KB
        $usedMemory = $totalMemory - $freeMemory
        $ramPercent = if ($totalMemory -gt 0) { [math]::Round(($usedMemory / $totalMemory) * 100, 2) } else { 0 }

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

        $internet = $false
        try {
            $internet = Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction Stop
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

    # ── Extended diagnostic sections ─────────────────────────────────────────
    Write-Host '  Scanning hardware details...' -ForegroundColor DarkGray -NoNewline
    try { $result.HardwareDetail = Get-WinPulseHardwareDetail }
    catch { $result.Errors += "HW DETAIL: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning temperatures...' -ForegroundColor DarkGray -NoNewline
    try { $result.Temperatures = Get-WinPulseTemperatures }
    catch { $result.Errors += "TEMPERATURES: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning TPM...' -ForegroundColor DarkGray -NoNewline
    try { $result.TPM = Get-WinPulseTPMStatus }
    catch { $result.Errors += "TPM: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning drivers (this may take a moment)...' -ForegroundColor DarkGray -NoNewline
    try { $result.Drivers = Get-WinPulseDriverAnalysis }
    catch { $result.Errors += "DRIVERS: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning startup items...' -ForegroundColor DarkGray -NoNewline
    try { $result.Startup = Get-WinPulseStartupAnalysis }
    catch { $result.Errors += "STARTUP: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning user accounts...' -ForegroundColor DarkGray -NoNewline
    try { $result.UserAccounts = Get-WinPulseUserAccounts }
    catch { $result.Errors += "USERS: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning network details...' -ForegroundColor DarkGray -NoNewline
    try { $result.NetworkDetail = Get-WinPulseNetworkDetail }
    catch { $result.Errors += "NETWORK DETAIL: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning installed software...' -ForegroundColor DarkGray -NoNewline
    try { $result.Software = Get-WinPulseSoftwareInventory }
    catch { $result.Errors += "SOFTWARE: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning printers...' -ForegroundColor DarkGray -NoNewline
    try { $result.Printers = Get-WinPulsePrinterStatus }
    catch { $result.Errors += "PRINTERS: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning license...' -ForegroundColor DarkGray -NoNewline
    try { $result.License = Get-WinPulseLicenseInfo }
    catch { $result.Errors += "LICENSE: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning scheduled tasks...' -ForegroundColor DarkGray -NoNewline
    try { $result.ScheduledTasks = Get-WinPulseScheduledTaskAnalysis }
    catch { $result.Errors += "SCHEDULED TASKS: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    Write-Host '  Scanning virtualization...' -ForegroundColor DarkGray -NoNewline
    try { $result.Virtualization = Get-WinPulseVirtualizationInfo }
    catch { $result.Errors += "VIRTUALIZATION: $($_.Exception.Message)" }
    Write-Host ' done' -ForegroundColor DarkGray

    return [pscustomobject]$result
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

function Write-WinPulseHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$title
    )

    $w = 62
    Write-Host ''
    Write-Host ('  {0}{1}{2}' -f ([char]0x250C), ([string][char]0x2500 * ($w - 2)), ([char]0x2510)) -ForegroundColor DarkCyan
    Write-Host -NoNewline ('  {0} ' -f ([char]0x2502)) -ForegroundColor DarkCyan
    Write-Host -NoNewline ('{0}' -f $title.PadRight($w - 4)) -ForegroundColor Cyan
    Write-Host (' {0}' -f ([char]0x2502)) -ForegroundColor DarkCyan
    Write-Host ('  {0}{1}{2}' -f ([char]0x2514), ([string][char]0x2500 * ($w - 2)), ([char]0x2518)) -ForegroundColor DarkCyan
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
        if (-not $Items[$i].Separator) { $selectableIdx += $i }
    }
    if ($selectableIdx.Count -eq 0) { return $null }

    # Check interactive capability
    $interactive = $true
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { $interactive = $false }

    $w = 62
    $hLine = [string][char]0x2500 * ($w - 2)
    $vLine = [char]0x2502

    if (-not $interactive) {
        Write-WinPulseHeader -title $Title
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($Items[$i].Separator) { Write-Host ''; continue }
            Write-Host ('  [{0}] {1}' -f $Items[$i].Key, $Items[$i].Label) -ForegroundColor White
        }
        $ch = (Read-Host '  Select').Trim().ToUpperInvariant()
        return $ch
    }

    [Console]::CursorVisible = $false
    $sel = 0
    try {
        $startY = [Console]::CursorTop
        $firstDraw = $true

        while ($true) {
            if (-not $firstDraw) { [Console]::SetCursorPosition(0, $startY) }
            $firstDraw = $false

            # Top border
            Write-Host ('  {0}{1} {2} {3}{4}' -f ([char]0x250C), ([string][char]0x2500 * 2), $Title, ([string][char]0x2500 * [math]::Max(1, $w - $Title.Length - 5)), ([char]0x2510)) -ForegroundColor DarkCyan

            for ($i = 0; $i -lt $Items.Count; $i++) {
                $item = $Items[$i]

                if ($item.Separator) {
                    Write-Host ('  {0}{1}{2}' -f $vLine, (' ' * ($w - 2)), $vLine) -ForegroundColor DarkCyan
                    continue
                }

                $isSelected = ($selectableIdx[$sel] -eq $i)
                $pointer = if ($isSelected) { [char]0x25BA } else { ' ' }
                $keyTag = if ($item.Key) { '[{0}]' -f $item.Key } else { '   ' }
                $hint = if ($item.Hint) { $item.Hint } else { '' }
                $color = if ($item.Color) { $item.Color } else { 'White' }

                $left = ' {0} {1} {2}' -f $pointer, $keyTag, $item.Label
                $avail = $w - 4
                $rightSpace = $avail - $left.Length
                if ($rightSpace -lt 0) { $left = $left.Substring(0, $avail); $rightSpace = 0 }
                $line = if ($hint -and $rightSpace -gt ($hint.Length + 2)) {
                    $left + (' ' * ($rightSpace - $hint.Length)) + $hint
                }
                else {
                    $left + (' ' * $rightSpace)
                }

                Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor DarkCyan
                if ($isSelected) {
                    Write-Host -NoNewline $line -ForegroundColor White -BackgroundColor DarkBlue
                }
                else {
                    Write-Host -NoNewline $line -ForegroundColor $color
                }
                Write-Host (' {0}' -f $vLine) -ForegroundColor DarkCyan
            }

            # Bottom border
            Write-Host ('  {0}{1}{2}' -f ([char]0x2514), $hLine, ([char]0x2518)) -ForegroundColor DarkCyan
            # Help bar
            $helpText = '  {0}/{1} Navigate  Enter Select  Esc Back' -f ([char]0x2191), ([char]0x2193)
            Write-Host ($helpText + (' ' * [math]::Max(0, $w - $helpText.Length + 2))) -ForegroundColor DarkGray

            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

            switch ($k.VirtualKeyCode) {
                38 { $sel = if ($sel -gt 0) { $sel - 1 } else { $selectableIdx.Count - 1 } }
                40 { $sel = if ($sel -lt $selectableIdx.Count - 1) { $sel + 1 } else { 0 } }
                13 { return $Items[$selectableIdx[$sel]].Key }
                27 { return $null }
                default {
                    $ch = [string]$k.Character
                    if ($ch) {
                        $ch = $ch.ToUpperInvariant()
                        $match = $Items | Where-Object { $_.Key -and $_.Key.ToUpperInvariant() -eq $ch -and -not $_.Separator }
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

function Write-WinPulseDashboardLine {
    [CmdletBinding()]
    param(
        [string]$Label,
        [string]$Value,
        [string]$State = 'Info',
        [int]$BoxWidth = 62
    )

    $badge = switch ($State) {
        'OK'       { @{ Text = ' OK '; Color = 'Green' } }
        'Warning'  { @{ Text = 'WARN'; Color = 'Yellow' } }
        'Critical' { @{ Text = 'CRIT'; Color = 'Red' } }
        default    { @{ Text = 'INFO'; Color = 'DarkCyan' } }
    }
    $vLine = [char]0x2502

    $inner = $BoxWidth - 4
    $content = ' [{0}] {1,-10} {2}' -f $badge.Text, $Label, $Value
    if ($content.Length -gt $inner) { $content = $content.Substring(0, $inner) }
    $content = $content.PadRight($inner)

    Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor DarkCyan
    Write-Host -NoNewline ' ' -ForegroundColor DarkCyan
    Write-Host -NoNewline ('[{0}]' -f $badge.Text) -ForegroundColor $badge.Color
    $rest = $content.Substring($badge.Text.Length + 3)
    Write-Host -NoNewline $rest -ForegroundColor Gray
    Write-Host (' {0}' -f $vLine) -ForegroundColor DarkCyan
}

function Show-WinPulseDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    Clear-Host
    $w = 62
    $hLine = [string][char]0x2500 * ($w - 2)
    $vLine = [char]0x2502

    # Top header
    Write-Host ''
    Write-Host ('  {0}{1} WinPulse {2}{3}' -f ([char]0x250C), ([string][char]0x2500 * 2), ([string][char]0x2500 * ($w - 13)), ([char]0x2510)) -ForegroundColor DarkCyan

    # System line
    $sysLine = ' {0} | {1} | up {2}' -f $scan.System.Hostname, $scan.System.WindowsVersion, $scan.System.Uptime
    if ($sysLine.Length -gt ($w - 4)) { $sysLine = $sysLine.Substring(0, $w - 4) }
    Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor DarkCyan
    Write-Host -NoNewline ($sysLine.PadRight($w - 4)) -ForegroundColor White
    Write-Host (' {0}' -f $vLine) -ForegroundColor DarkCyan

    # Separator
    Write-Host ('  {0}{1}{2}' -f ([char]0x251C), $hLine, ([char]0x2524)) -ForegroundColor DarkCyan

    # Hardware
    $ramState = Get-WinPulseStateFromPercent -percent $scan.Hardware.Ram.UsedPercent
    $cDisk = $scan.Hardware.Disks | Where-Object { $_.Drive -eq 'C:' } | Select-Object -First 1
    $cDiskText = if ($cDisk) { 'C: {0}% free:{1}' -f $cDisk.UsedPercent, $cDisk.Free } else { 'C: N/A' }
    Write-WinPulseDashboardLine -Label 'Hardware' -Value ('RAM {0}% | {1} | SMART {2}' -f $scan.Hardware.Ram.UsedPercent, $cDiskText, $(if ($scan.Hardware.SmartHealthy) { 'OK' } else { 'FAIL' })) -State $ramState

    # Details (CPU/GPU/TPM)
    if ($scan.HardwareDetail) {
        $cpuShort = if ($scan.HardwareDetail.CPU.Model -ne 'N/A') { ($scan.HardwareDetail.CPU.Model -replace '\s*(CPU|Processor|\(R\)|\(TM\)|@\s*[\d.]+GHz)\s*', ' ').Trim() -replace '\s+', ' ' } else { 'N/A' }
        if ($cpuShort.Length -gt 22) { $cpuShort = $cpuShort.Substring(0, 22) }
        $tpmLabel = if ($scan.TPM) { 'TPM {0}' -f $scan.TPM.Version } else { 'TPM N/A' }
        $ramType = if ($scan.HardwareDetail.DIMMs.Count -gt 0) { $scan.HardwareDetail.DIMMs[0].Type } else { '' }
        Write-WinPulseDashboardLine -Label 'Details' -Value ('{0} | {1} | {2}' -f $cpuShort, $tpmLabel, $ramType) -State 'Info'
    }

    # Security
    $avNames = @()
    if ($scan.Security.Antivirus -and $scan.Security.Antivirus.Products) {
        $avNames = @($scan.Security.Antivirus.Products | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    $avLabel = if ($avNames.Count -gt 0) { ($avNames -join ', ') } else { 'None' }
    if ($avLabel.Length -gt 18) { $avLabel = $avLabel.Substring(0, 18) }
    $fwLabel = if ($scan.Security.FirewallEnabled) { 'ON' } else { 'OFF' }
    $bitLockerOn = $false
    if ($scan.Security.BitLocker -and $scan.Security.BitLocker.Count -gt 0) {
        $bitLockerOn = @($scan.Security.BitLocker | Where-Object { ([string]$_.ProtectionStatus) -match 'On|1' }).Count -gt 0
    }
    $blLabel = if ($bitLockerOn) { 'ON' } else { 'OFF' }
    $secState = if ($scan.Security.Antivirus.EffectiveRealtimeProtection -and $scan.Security.FirewallEnabled) { 'OK' } else { 'Critical' }
    Write-WinPulseDashboardLine -Label 'Security' -Value ('AV {0} | FW {1} | BL {2}' -f $avLabel, $fwLabel, $blLabel) -State $secState

    # Network
    $netState = if ($scan.Network.Internet) { 'OK' } else { 'Warning' }
    Write-WinPulseDashboardLine -Label 'Network' -Value ('{0} | GW {1} | Net {2}' -f $scan.Network.IPv4, $scan.Network.Gateway, $(if ($scan.Network.Internet) { 'OK' } else { 'FAIL' })) -State $netState

    # Health
    $healthState = if ($scan.Health.CriticalLast24Hours -eq 0 -and -not $scan.Health.PendingReboot -and $scan.Health.BsodRecentCount -eq 0) { 'OK' } elseif ($scan.Health.BsodRecentCount -gt 0 -or $scan.Health.CriticalLast24Hours -gt 0) { 'Critical' } else { 'Warning' }
    Write-WinPulseDashboardLine -Label 'Health' -Value ('BSOD {0} | Crit24 {1} | Reboot {2}' -f $scan.Health.BsodRecentCount, $scan.Health.CriticalLast24Hours, $(if ($scan.Health.PendingReboot) { 'YES' } else { 'No' })) -State $healthState

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

    # Findings separator
    Write-Host ('  {0}{1}{2}' -f ([char]0x251C), $hLine, ([char]0x2524)) -ForegroundColor DarkCyan

    $findings = @(Get-WinPulseTriageFindings -scan $scan)
    if ($findings.Count -eq 0) {
        $fLine = ' No issues detected'
        Write-Host -NoNewline ('  {0}' -f $vLine) -ForegroundColor DarkCyan
        Write-Host -NoNewline (' {0}' -f $fLine.PadRight($w - 4)) -ForegroundColor Green
        Write-Host (' {0}' -f $vLine) -ForegroundColor DarkCyan
    }
    else {
        $top = @($findings | Sort-Object @{ Expression = { if ($_.Severity -eq 'Critical') { 0 } else { 1 } } } | Select-Object -First 2)
        foreach ($f in $top) {
            $fColor = if ($f.Severity -eq 'Critical') { 'Red' } else { 'Yellow' }
            $fBadge = if ($f.Severity -eq 'Critical') { '!!' } else { '! ' }
            $fText = ' {0} {1}' -f $fBadge, $f.Message
            if ($fText.Length -gt ($w - 4)) { $fText = $fText.Substring(0, $w - 7) + '...' }
            Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor DarkCyan
            Write-Host -NoNewline ($fText.PadRight($w - 4)) -ForegroundColor $fColor
            Write-Host (' {0}' -f $vLine) -ForegroundColor DarkCyan
        }
        if ($findings.Count -gt 2) {
            $moreText = ' ... +{0} more findings' -f ($findings.Count - 2)
            Write-Host -NoNewline ('  {0} ' -f $vLine) -ForegroundColor DarkCyan
            Write-Host -NoNewline ($moreText.PadRight($w - 4)) -ForegroundColor DarkYellow
            Write-Host (' {0}' -f $vLine) -ForegroundColor DarkCyan
        }
    }

    # Bottom border
    Write-Host ('  {0}{1}{2}' -f ([char]0x2514), $hLine, ([char]0x2518)) -ForegroundColor DarkCyan
    Write-Host ('  Scanned: {0}' -f $scan.GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

    if ($scan.Errors.Count -gt 0) {
        Write-Host ''
        Write-Host ('  Scan warnings: {0}' -f $scan.Errors.Count) -ForegroundColor Yellow
    }
    Write-Host ''
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
    if ($scan.Errors.Count -gt 0) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('Scan warnings present: {0}' -f $scan.Errors.Count) }
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
    if ($scan.HardwareDetail -and $scan.HardwareDetail.Battery.Present -and $scan.HardwareDetail.Battery.HealthPercent -and $scan.HardwareDetail.Battery.HealthPercent -lt 50) {
        $findings += [pscustomobject]@{ Severity = 'Warning'; Message = ('Battery health is low: {0}%' -f $scan.HardwareDetail.Battery.HealthPercent) }
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
    Write-Host 'Top findings:' -ForegroundColor DarkCyan
    foreach ($item in $top) {
        $color = if ($item.Severity -eq 'Critical') { 'Red' } elseif ($item.Severity -eq 'Warning') { 'Yellow' } else { 'White' }
        Write-Host ('- [{0}] {1}' -f $item.Severity.ToUpperInvariant(), $item.Message) -ForegroundColor $color
    }
}

# ── HTML Report ──────────────────────────────────────────────────────────────

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

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $e = [System.Web.HttpUtility]

    $findings = @(Get-WinPulseTriageFindings -scan $scan)
    $overall = 'OK'
    if ($findings | Where-Object { $_.Severity -eq 'Critical' }) { $overall = 'CRITICAL' }
    elseif ($findings.Count -gt 0) { $overall = 'WARNING' }
    $overallClass = switch ($overall) { 'CRITICAL' { 'state-crit' }; 'WARNING' { 'state-warn' }; default { 'state-ok' } }

    $sb = [System.Text.StringBuilder]::new()

    # ── HTML Head ────────────────────────────────────────────────────────────
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

    # ── Header ───────────────────────────────────────────────────────────────
    [void]$sb.Append(('<header><h1>WinPulse Diagnostic Report</h1><p class="subtitle">{0} | Generated: {1}</p>' -f $e::HtmlEncode($scan.System.Hostname), $scan.GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$sb.Append(('<div class="overall-badge {0}">Overall: {1}</div>' -f $overallClass, $overall))
    [void]$sb.Append('</header>')

    # ── Triage ───────────────────────────────────────────────────────────────
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

    # ── Technician Notes ─────────────────────────────────────────────────────
    [void]$sb.Append('<section><h2>Technician Notes</h2><textarea class="notes-area" placeholder="Add notes here before printing..."></textarea></section>')

    # ── System Info ──────────────────────────────────────────────────────────
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

    # ── Hardware Details ─────────────────────────────────────────────────────
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

    # ── RAM & Disk ───────────────────────────────────────────────────────────
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

    # ── Temperatures ─────────────────────────────────────────────────────────
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

    # ── TPM ──────────────────────────────────────────────────────────────────
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

    # ── Security ─────────────────────────────────────────────────────────────
    [void]$sb.Append('<section><h2>Security</h2><div class="kv">')
    $avLabel = if ($scan.Security.Antivirus.Products.Count -gt 0) { ($scan.Security.Antivirus.Products | ForEach-Object { $_.Name } | Where-Object { $_ } | Sort-Object -Unique) -join ', ' } else { 'None detected' }
    [void]$sb.Append(('<span class="k">Antivirus</span><span class="v">{0}</span>' -f $e::HtmlEncode($avLabel)))
    [void]$sb.Append(('<span class="k">Real-time Protection</span><span class="v {0}">{1}</span>' -f $(if ($scan.Security.Antivirus.EffectiveRealtimeProtection) { 'state-ok' } else { 'state-crit' }), $scan.Security.Antivirus.EffectiveRealtimeProtection))
    [void]$sb.Append(('<span class="k">Firewall</span><span class="v {0}">{1}</span>' -f $(if ($scan.Security.FirewallEnabled) { 'state-ok' } else { 'state-crit' }), $(if ($scan.Security.FirewallEnabled) { 'Enabled' } else { 'DISABLED' })))
    $blOn = $false
    if ($scan.Security.BitLocker -and $scan.Security.BitLocker.Count -gt 0) { $blOn = @($scan.Security.BitLocker | Where-Object { ([string]$_.ProtectionStatus) -match 'On|1' }).Count -gt 0 }
    [void]$sb.Append(('<span class="k">BitLocker</span><span class="v">{0}</span>' -f $(if ($blOn) { 'On' } else { 'Off' })))
    [void]$sb.Append('</div></section>')

    # ── License ──────────────────────────────────────────────────────────────
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

    # ── Health & Events ──────────────────────────────────────────────────────
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

    # ── Network ──────────────────────────────────────────────────────────────
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

    # ── Drivers ──────────────────────────────────────────────────────────────
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

    # ── Startup ──────────────────────────────────────────────────────────────
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

    # ── User Accounts ────────────────────────────────────────────────────────
    if ($scan.UserAccounts) {
        [void]$sb.Append('<section><h2>User Accounts</h2>')
        [void]$sb.Append(('<p style="color:var(--muted);font-size:0.9em">User profiles on disk: {0}</p>' -f $scan.UserAccounts.ProfileCount))
        if ($scan.UserAccounts.Users.Count -gt 0) {
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.UserAccounts.Users))
        }
        [void]$sb.Append('</section>')
    }

    # ── Printers ─────────────────────────────────────────────────────────────
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

    # ── Software Inventory ───────────────────────────────────────────────────
    if ($scan.Software) {
        [void]$sb.Append(('<section><h2>Installed Software ({0})</h2>' -f $scan.Software.Count))
        if ($scan.Software.Items.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Show all {0} programs</summary>' -f $scan.Software.Count))
            [void]$sb.Append((ConvertTo-WinPulseHtmlTable -Data $scan.Software.Items))
            [void]$sb.Append('</details>')
        }
        [void]$sb.Append('</section>')
    }

    # ── Scheduled Tasks ──────────────────────────────────────────────────────
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

    # ── Virtualization ───────────────────────────────────────────────────────
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

    # ── Scan Warnings ────────────────────────────────────────────────────────
    if ($scan.Errors.Count -gt 0) {
        [void]$sb.Append('<section><h2>Scan Warnings</h2><ul class="findings-list">')
        foreach ($err in $scan.Errors) {
            [void]$sb.Append(('<li class="bg-warn state-warn">{0}</li>' -f $e::HtmlEncode($err)))
        }
        [void]$sb.Append('</ul></section>')
    }

    # ── Footer ───────────────────────────────────────────────────────────────
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

# ── End HTML Report ──────────────────────────────────────────────────────────

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
    Write-Host ('Showing critical/error events since: {0}' -f $since.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkCyan

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
            Write-Host ('Direct link: {0}' -f $directUrl) -ForegroundColor DarkYellow
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
    Write-Host ('Direct link used: {0}' -f $directUrl) -ForegroundColor DarkYellow
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
        Write-Host ('TechToolStore download failed: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
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

    Write-Host 'NirLauncher launch failed (portable + winget fallback). Opening official page...' -ForegroundColor DarkYellow
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
            Write-Host ('Direct link: {0}' -f $directUrl) -ForegroundColor DarkYellow
            return
        }
    }

    if (Test-Path -Path $targetExe) {
        Start-Process -FilePath $targetExe
        return
    }

    Write-Host 'O&O executable not found after direct download.' -ForegroundColor Red
    Write-Host 'Direct link used: https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -ForegroundColor DarkYellow
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
            Write-Host ("Using existing CrystalDiskInfo package: {0}" -f $installedPackageId) -ForegroundColor DarkCyan
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
                    Write-Host ('CrystalDiskInfo uninstall warning: {0}' -f (($uninstallOutput | Out-String).Trim())) -ForegroundColor DarkYellow
                }
            }
            catch {
                Write-Host ('CrystalDiskInfo uninstall warning: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
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
        Write-Host 'Tip: Use CrystalDiskInfo for vendor-specific details.' -ForegroundColor DarkYellow
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
            Write-Host 'Reboot is required. Save work and restart the device.' -ForegroundColor Yellow
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
    Write-Host '[1] Dry Run (show plan only)'
    Write-Host '[2] Execute repair now'
    Write-Host '[0] Cancel'
    $mode = Read-Host 'Select mode'
    if ($mode -eq '0') {
        return $scan
    }

    if ($mode -eq '1') {
        Invoke-WinPulseRepairPlan -planid $plan.Id -dryrun
        Write-Host 'Dry run complete. No changes were made.' -ForegroundColor Green
        return $scan
    }

    if ($mode -ne '2') {
        Write-Host 'Invalid mode.' -ForegroundColor Yellow
        return $scan
    }

    $confirm = Read-Host ('Execute "{0}" now? (y/n)' -f $plan.Label)
    if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Repair cancelled.' -ForegroundColor Yellow
        return $scan
    }

    Invoke-WinPulseRepairPlan -planid $plan.Id
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

function Invoke-WinGetInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$id
    )

    & winget install --id $id --accept-source-agreements --accept-package-agreements --silent
}

function Test-WinGetAvailable {
    [CmdletBinding()]
    param()

    return [bool](Get-Command -Name winget -ErrorAction SilentlyContinue)
}

function Get-WinPulsePackageCatalog {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Name = '7-Zip'; Id = '7zip.7zip'; Category = 'Tools'; InBasicSet = $true }
        [pscustomobject]@{ Name = 'Google Chrome'; Id = 'Google.Chrome'; Category = 'Browser'; InBasicSet = $true }
        [pscustomobject]@{ Name = 'Notepad++'; Id = 'Notepad++.Notepad++'; Category = 'Tools'; InBasicSet = $false }
        [pscustomobject]@{ Name = 'VLC'; Id = 'VideoLAN.VLC'; Category = 'Media'; InBasicSet = $true }
        [pscustomobject]@{ Name = 'PowerToys'; Id = 'Microsoft.PowerToys'; Category = 'Tools'; InBasicSet = $false }
        [pscustomobject]@{ Name = 'LibreOffice'; Id = 'TheDocumentFoundation.LibreOffice'; Category = 'Office'; InBasicSet = $false }
        [pscustomobject]@{ Name = 'Microsoft 365 Apps'; Id = 'Microsoft.Office'; Category = 'Office'; InBasicSet = $false }
        [pscustomobject]@{ Name = 'Firefox'; Id = 'Mozilla.Firefox'; Category = 'Browser'; InBasicSet = $false }
        [pscustomobject]@{ Name = 'Adobe Acrobat Reader'; Id = 'Adobe.Acrobat.Reader.64-bit'; Category = 'PDF'; InBasicSet = $true }
        [pscustomobject]@{ Name = 'TeamViewer'; Id = 'TeamViewer.TeamViewer'; Category = 'Remote'; InBasicSet = $false }
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

    Write-Host ('{0,3}  {1,-26} {2,-34} {3,-10} {4}' -f '#', 'Name', 'Winget ID', 'Category', 'Installed') -ForegroundColor DarkCyan
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$packages,

        [switch]$dryrun
    )

    foreach ($pkg in $packages) {
        if ($dryrun) {
            Write-Host ('[DRY RUN] Install {0} ({1})' -f $pkg.Name, $pkg.Id) -ForegroundColor Cyan
            continue
        }

        Write-Host ('Installing {0} ({1})' -f $pkg.Name, $pkg.Id) -ForegroundColor White
        Invoke-WinGetInstall -id $pkg.Id
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

    $confirm = Read-Host 'Install all packages above? (y/n)'
    if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }

    Invoke-WinPulsePackageInstall -packages $packages
}

function Invoke-WinPulseCustomInstall {
    [CmdletBinding()]
    param(
        [switch]$dryrun
    )

    $catalog = @(Get-WinPulsePackageCatalog)
    Write-WinPulseHeader -title 'Custom Install'
    Show-WinPulsePackageTable -packages $catalog
    $selectedIndexes = @(Read-WinPulseSelection -max $catalog.Count)
    if ($selectedIndexes.Count -eq 0) {
        Write-Host 'No valid selection.' -ForegroundColor Yellow
        return
    }

    $selected = foreach ($index in $selectedIndexes) { $catalog[$index - 1] }
    Write-Host ''
    Write-Host 'Selected for install:' -ForegroundColor Cyan
    foreach ($pkg in $selected) { Write-Host ('- {0} ({1})' -f $pkg.Name, $pkg.Id) }
    Write-Host ''

    if (-not $dryrun) {
        $confirm = Read-Host 'Continue? (y/n)'
        if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            return
        }
    }

    Invoke-WinPulsePackageInstall -packages $selected -dryrun:$dryrun
}

function Invoke-WinPulseCustomUninstall {
    [CmdletBinding()]
    param(
        [switch]$dryrun
    )

    $catalog = @(Get-WinPulsePackageCatalog)
    $installed = @()
    foreach ($pkg in $catalog) {
        if (Test-WinPulsePackageInstalled -id $pkg.Id) {
            $installed += $pkg
        }
    }

    if ($installed.Count -eq 0) {
        Write-Host 'No catalog packages currently installed.' -ForegroundColor Yellow
        return
    }

    Write-WinPulseHeader -title 'Custom Uninstall'
    Show-WinPulsePackageTable -packages $installed
    $selectedIndexes = @(Read-WinPulseSelection -max $installed.Count)
    if ($selectedIndexes.Count -eq 0) {
        Write-Host 'No valid selection.' -ForegroundColor Yellow
        return
    }

    $selected = foreach ($index in $selectedIndexes) { $installed[$index - 1] }
    Write-Host ''
    Write-Host 'Selected for uninstall:' -ForegroundColor Cyan
    foreach ($pkg in $selected) { Write-Host ('- {0} ({1})' -f $pkg.Name, $pkg.Id) }
    Write-Host ''

    if (-not $dryrun) {
        $confirm = Read-Host 'Continue? (y/n)'
        if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            return
        }
    }

    Invoke-WinPulsePackageUninstall -packages $selected -dryrun:$dryrun
}

function Update-AllApplications {
    [CmdletBinding()]
    param()

    & winget upgrade --all --accept-source-agreements --accept-package-agreements --silent
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
        [pscustomobject]@{ Name = 'Office 2019 Home and Business (CZ)'; ProductId = 'HomeBusiness2019Retail'; Channel = $null; Version = '2019'; Edition = 'HomeBusiness' }
        [pscustomobject]@{ Name = 'Office 2019 Home (CZ)'; ProductId = 'HomeStudent2019Retail'; Channel = $null; Version = '2019'; Edition = 'Home' }
        [pscustomobject]@{ Name = 'Office 2019 Standard Volume (CZ)'; ProductId = 'Standard2019Volume'; Channel = 'PerpetualVL2019'; Version = '2019'; Edition = 'StandardVolume' }
        [pscustomobject]@{ Name = 'Office 2021 Home and Business (CZ)'; ProductId = 'HomeBusiness2021Retail'; Channel = $null; Version = '2021'; Edition = 'HomeBusiness' }
        [pscustomobject]@{ Name = 'Office 2021 Home (CZ)'; ProductId = 'HomeStudent2021Retail'; Channel = $null; Version = '2021'; Edition = 'Home' }
        [pscustomobject]@{ Name = 'Office 2021 Standard Volume (CZ)'; ProductId = 'Standard2021Volume'; Channel = 'PerpetualVL2021'; Version = '2021'; Edition = 'StandardVolume' }
        [pscustomobject]@{ Name = 'Office 2024 Home and Business (CZ)'; ProductId = 'HomeBusiness2024Retail'; Channel = $null; Version = '2024'; Edition = 'HomeBusiness' }
        [pscustomobject]@{ Name = 'Office 2024 Home (CZ)'; ProductId = 'HomeStudent2024Retail'; Channel = $null; Version = '2024'; Edition = 'Home' }
        [pscustomobject]@{ Name = 'Office 2024 Standard Volume (CZ)'; ProductId = 'Standard2024Volume'; Channel = 'PerpetualVL2024'; Version = '2024'; Edition = 'StandardVolume' }
        [pscustomobject]@{ Name = 'Microsoft 365 Home (CZ)'; ProductId = 'O365HomePremRetail'; Channel = 'Current'; Version = '365'; Edition = 'Home' }
        [pscustomobject]@{ Name = 'Microsoft 365 Business (CZ)'; ProductId = 'O365BusinessRetail'; Channel = 'Current'; Version = '365'; Edition = 'Business' }
    )
}

function Get-WinPulseOfficeSetupPath {
    [CmdletBinding()]
    param()

    $candidates = @(
        (Join-Path $script:WinPulsePaths.Bin 'OfficeODT\setup.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\setup.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\setup.exe')
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -Path $path)) {
            return $path
        }
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

    if (-not (Test-WinGetAvailable)) {
        throw 'Office setup.exe not found and winget is unavailable for Office Deployment Tool installation.'
    }

    Write-Log -level 'INFO' -message 'Installing Microsoft Office Deployment Tool via winget.'
    & winget install --id Microsoft.OfficeDeploymentTool --accept-source-agreements --accept-package-agreements --silent

    $setupPath = Get-WinPulseOfficeSetupPath
    if (-not $setupPath) {
        throw 'Office Deployment Tool setup.exe not found after installation.'
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
    Write-WinPulseHeader -title 'Office Install'
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        Write-Host ('[{0}] {1}' -f ($i + 1), $catalog[$i].Name)
    }
    Write-Host '[0] Back'

    $choice = Read-Host 'Select Office edition'
    if ($choice -eq '0') {
        return
    }

    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index)) {
        Write-Host 'Invalid selection.' -ForegroundColor Yellow
        return
    }

    $selection = $catalog | Select-Object -Index ($index - 1) -ErrorAction SilentlyContinue
    if (-not $selection) {
        Write-Host 'Invalid selection.' -ForegroundColor Yellow
        return
    }

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

    Write-Host ''
    Write-Host ('Selected: {0}' -f $selection.Name) -ForegroundColor Cyan
    Write-Host ('Product ID: {0}' -f $selection.ProductId)
    if ($selection.Channel) {
        Write-Host ('Channel: {0}' -f $selection.Channel)
    }
    $confirm = Read-Host 'Continue with Office install? (y/n)'
    if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }

    Invoke-WinPulseOfficeConfiguration -xmlcontent $xml -description ('Office install - {0}' -f $selection.Name)
}

function Uninstall-WinPulseOffice {
    [CmdletBinding()]
    param()

    $xml = @"
<Configuration>
  <Remove All="TRUE" />
  <Display Level="Full" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@

    Write-Host 'This will uninstall Office products managed by Click-to-Run.' -ForegroundColor Yellow
    $confirm = Read-Host 'Continue with Office uninstall? (y/n)'
    if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }

    Invoke-WinPulseOfficeConfiguration -xmlcontent $xml -description 'Office uninstall'
}

function Repair-WinPulseOffice {
    [CmdletBinding()]
    param()

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
        $choice = Select-WinPulseMenuItem -Title 'Office' -Items @(
            @{ Label = 'Install Office';    Key = 'I'; Hint = 'Version/CZ' },
            @{ Label = 'Uninstall Office';  Key = 'U'; Hint = 'Remove' },
            @{ Label = 'Repair Office';     Key = 'R'; Hint = 'Fix install' },
            @{ Separator = $true },
            @{ Label = 'Back';              Key = 'B'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'I' { try { Install-WinPulseOffice } catch { Write-Host ("  Office install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }; Read-Host '  Press Enter' | Out-Null }
            'U' { try { Uninstall-WinPulseOffice } catch { Write-Host ("  Office uninstall failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }; Read-Host '  Press Enter' | Out-Null }
            'R' { try { Repair-WinPulseOffice } catch { Write-Host ("  Office repair failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }; Read-Host '  Press Enter' | Out-Null }
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

    $confirm = Read-Host 'Type YES to fully remove C:\ProgramData\WinPulse'
    if ($confirm -ne 'YES') {
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
                Write-Host 'CPU counter unavailable on this system.' -ForegroundColor DarkYellow
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
            Write-Host ('RAM sample failed: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
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
    Write-Host 'For full RAM diagnostics use Windows Memory Diagnostic (reboot required).' -ForegroundColor DarkYellow
}

function Start-WinPulseMemoryDiagnostic {
    [CmdletBinding()]
    param()

    Write-Host 'Windows Memory Diagnostic requires reboot.' -ForegroundColor Yellow
    $confirm = Read-Host 'Open memory diagnostic tool now? (y/n)'
    if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
        return
    }

    Start-Process -FilePath 'mdsched.exe'
}

function Start-WinPulseFurMarkAdvanced {
    [CmdletBinding()]
    param()

    Write-Host 'Warning: FurMark is aggressive GPU stress. Use only on non-production tests.' -ForegroundColor Yellow
    $confirm = Read-Host 'Continue and try to launch FurMark? (y/n)'
    if ($confirm -notin @('y', 'Y', 'yes', 'YES')) {
        return
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
            Write-Host ("Using existing FurMark package: {0}" -f $installedPackageId) -ForegroundColor DarkCyan
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
            Write-Host 'Close FurMark when done, then press Enter to continue cleanup.' -ForegroundColor DarkYellow
            [void](Read-Host)
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
                    Write-Host ('FurMark uninstall warning: {0}' -f (($uninstallOutput | Out-String).Trim())) -ForegroundColor DarkYellow
                }
            }
            catch {
                Write-Host ('FurMark uninstall warning: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
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
        Write-Host ('StressMyPC portable lookup failed: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
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
            @{ Label = 'FurMark';                  Key = 'F'; Hint = 'GPU stress' },
            @{ Separator = $true },
            @{ Label = 'Back';                     Key = 'B'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'C' { Invoke-WinPulseCpuStressTest -durationseconds 60 }
            'D' { Invoke-WinPulseDiskStressTest -sizemb 512 }
            'R' { Invoke-WinPulseRamQuickTest -durationseconds 20 }
            'M' { Start-WinPulseMemoryDiagnostic }
            'S' { Start-WinPulseStressMyPC }
            'F' { Start-WinPulseFurMarkAdvanced }
            default { return }
        }
        Write-Host ''; Read-Host '  Press Enter to continue' | Out-Null
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
                Write-Host 'Top event providers:' -ForegroundColor DarkCyan
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

            Write-Host 'Storage inventory:' -ForegroundColor DarkCyan
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
        Write-Host 'For full offline RAM diagnostics schedule: mdsched.exe' -ForegroundColor DarkYellow

        Write-Host ''
        Write-WinPulseHeader -title 'Diagnostics Summary'
        Write-Host ('OK: {0} | WARN: {1} | CRIT: {2}' -f $score.OK, $score.WARN, $score.CRIT) -ForegroundColor Cyan
        Write-Host 'Diagnostics complete.' -ForegroundColor Green
    }

    Clear-Host
    Invoke-WinPulseUnifiedDiagnostics
    Write-Host ''
    Read-Host 'Press Enter to continue' | Out-Null
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
            @{ Label = 'Process Explorer';      Key = 'I'; Hint = 'Sysinternals' },
            @{ Separator = $true },
            @{ Label = 'Back';                  Key = 'Q'; Color = 'DarkGray' }
        )
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
        Write-Host ''; Read-Host '  Press Enter to continue' | Out-Null
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
            @{ Label = 'Safe actions';             Key = 'S'; Hint = 'DISM/SFC/CHKDSK' },
            @{ Separator = $true },
            @{ Label = 'Back';                     Key = 'B'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'W' {
                $latestScan = Invoke-CoreScan
                Show-WindowsUpdateErrorDetails -scan $latestScan
                $scan = $latestScan
                Read-Host '  Press Enter to continue' | Out-Null
            }
            'P' {
                $plans = @(Get-WinPulseRepairPlans -scan $scan)
                if ($plans.Count -eq 0) {
                    Write-Host '  No repair plans detected for current state.' -ForegroundColor Green
                    Read-Host '  Press Enter to continue' | Out-Null
                    continue
                }

                Write-Host '  Detected plans:' -ForegroundColor Cyan
                for ($i = 0; $i -lt $plans.Count; $i++) {
                    $number = $i + 1
                    Write-Host ('  [{0}] {1} - {2}' -f $number, $plans[$i].Label, $plans[$i].Reason)
                }
                Write-Host '  [0] Back'
                $planChoice = (Read-Host '  Select plan').Trim()
                if ($planChoice -eq '0') { continue }

                $index = 0
                if (-not [int]::TryParse($planChoice, [ref]$index)) {
                    Write-Host '  Invalid plan choice.' -ForegroundColor Yellow
                    Read-Host '  Press Enter to continue' | Out-Null
                    continue
                }

                $selected = $plans | Select-Object -Index ($index - 1) -ErrorAction SilentlyContinue
                if (-not $selected) {
                    Write-Host '  Invalid plan choice.' -ForegroundColor Yellow
                    Read-Host '  Press Enter to continue' | Out-Null
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

    if (-not (Test-WinGetAvailable)) {
        Write-Host '  Winget is not available on this system.' -ForegroundColor Red
        return
    }

    while ($true) {
        Clear-Host
        $choice = Select-WinPulseMenuItem -Title 'Install / Apps' -Items @(
            @{ Label = 'Preview Basic IT Set';    Key = 'P'; Hint = 'Show list' },
            @{ Label = 'Install Basic IT Set';    Key = 'B'; Hint = 'Auto-install' },
            @{ Label = 'Custom install';          Key = 'C'; Hint = 'Multi-select' },
            @{ Label = 'Custom uninstall';        Key = 'U'; Hint = 'Multi-select' },
            @{ Label = 'Update all apps';         Key = 'A'; Hint = 'winget upgrade' },
            @{ Label = 'Office menu';             Key = 'O'; Hint = 'Install/repair' },
            @{ Separator = $true },
            @{ Label = 'Dry run: Basic IT';       Key = 'D'; Hint = 'Preview only'; Color = 'DarkGray' },
            @{ Label = 'Dry run: Install';        Key = 'I'; Hint = 'Preview only'; Color = 'DarkGray' },
            @{ Label = 'Dry run: Uninstall';      Key = 'N'; Hint = 'Preview only'; Color = 'DarkGray' },
            @{ Separator = $true },
            @{ Label = 'Back';                    Key = 'Q'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'P' { $preview = @(Get-WinPulsePackageCatalog | Where-Object { $_.InBasicSet }); Write-WinPulseHeader -title 'Basic IT Set Preview'; Show-WinPulsePackageTable -packages $preview; Read-Host '  Press Enter to continue' | Out-Null }
            'B' { Install-BasicITSet; Read-Host '  Press Enter to continue' | Out-Null }
            'C' { Invoke-WinPulseCustomInstall; Read-Host '  Press Enter to continue' | Out-Null }
            'U' { Invoke-WinPulseCustomUninstall; Read-Host '  Press Enter to continue' | Out-Null }
            'A' { Update-AllApplications; Read-Host '  Press Enter to continue' | Out-Null }
            'O' { Show-WinPulseOfficeMenu }
            'D' { Install-BasicITSet -dryrun; Read-Host '  Press Enter to continue' | Out-Null }
            'I' { Invoke-WinPulseCustomInstall -dryrun; Read-Host '  Press Enter to continue' | Out-Null }
            'N' { Invoke-WinPulseCustomUninstall -dryrun; Read-Host '  Press Enter to continue' | Out-Null }
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
    Write-Host '  Planned: curated safe tweaks with clear revert support.' -ForegroundColor DarkYellow
    Write-Host ''
    Read-Host '  Press Enter to return' | Out-Null
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
        @{ Label = 'Repair network';       Key = 'R'; Hint = 'Auto-fix' },
        @{ Separator = $true },
        @{ Label = 'Back';                 Key = 'B'; Color = 'DarkGray' }
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
        @{ Label = 'BitLocker status';        Key = 'B'; Hint = 'Encryption' },
        @{ Separator = $true },
        @{ Label = 'Back';                    Key = 'Q'; Color = 'DarkGray' }
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
            @{ Label = 'Remove WinPulse folder';   Key = 'F'; Hint = 'Complete'; Color = 'DarkYellow' },
            @{ Separator = $true },
            @{ Label = 'Back';                     Key = 'B'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'A' { Invoke-WinPulseFullArtifactCleanup; Read-Host '  Press Enter to continue' | Out-Null }
            'L' { Invoke-WinPulseLightCleanup; Read-Host '  Press Enter to continue' | Out-Null }
            'F' { Remove-WinPulseCompletely; Read-Host '  Press Enter to continue' | Out-Null }
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
        Write-Host ('WinPulse root folder removal warning: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Show-WinPulseExportMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        $choice = Select-WinPulseMenuItem -Title 'Export' -Items @(
            @{ Label = 'Export Scan JSON';    Key = 'J'; Hint = '.json' },
            @{ Label = 'Export HTML Report';  Key = 'H'; Hint = '.html' },
            @{ Separator = $true },
            @{ Label = 'Back';                Key = 'B'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'J' {
                $target = Join-Path $script:WinPulsePaths.Exports ('scan-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $scan | ConvertTo-Json -Depth 6 | Set-Content -Path $target -Encoding UTF8
                Write-Host ("  Exported: {0}" -f $target) -ForegroundColor Green
                Read-Host '  Press Enter to continue' | Out-Null
            }
            'H' {
                Export-WinPulseHtmlReport -scan $scan
                Read-Host '  Press Enter to continue' | Out-Null
            }
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
            @{ Label = 'Install / Apps';    Key = 'I'; Hint = 'Packages' },
            @{ Label = 'Repairs (Guided)';  Key = 'R'; Hint = 'Fix issues' },
            @{ Label = 'External Tools';    Key = 'T'; Hint = 'Portable apps' },
            @{ Label = 'Tweaks';            Key = 'W'; Hint = 'Optimize' },
            @{ Label = 'Cleanup';           Key = 'C'; Hint = 'Remove files' },
            @{ Label = 'Export';            Key = 'X'; Hint = 'JSON / HTML' },
            @{ Separator = $true },
            @{ Label = 'Exit';              Key = 'E'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'D' { Invoke-WinPulseDiagnostics; Write-Host ''; Read-Host '  Press Enter to continue' | Out-Null }
            'I' { Show-WinPulseInstallMenu }
            'R' { $scan = Invoke-WinPulseRepairs -scan $scan }
            'T' { Show-WinPulseToolsMenu }
            'W' { Show-WinPulseTweaksMenu }
            'C' { Show-WinPulseCleanupMenu }
            'X' { Show-WinPulseExportMenu -scan $scan }
            'E' { Invoke-WinPulseExitCleanupPrompt; return }
            default { }
        }
    }
}

function Show-WinPulseTriageMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        Show-WinPulseDashboard -scan $scan
        Show-WinPulseTriageSummary -scan $scan
        $choice = Select-WinPulseMenuItem -Title 'Quick Triage' -Items @(
            @{ Label = 'Re-scan';         Key = 'R'; Hint = 'Refresh data' },
            @{ Label = 'Inspect logs';    Key = 'L'; Hint = 'Last 24h' },
            @{ Label = 'Safe actions';    Key = 'S'; Hint = 'DISM/SFC/CHKDSK' },
            @{ Label = 'Full menu';       Key = 'M'; Hint = 'All options' },
            @{ Separator = $true },
            @{ Label = 'Exit';            Key = 'E'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'R' { $scan = Invoke-CoreScan }
            'L' { Clear-Host; Show-WinPulseEventLogInspection -hourback 24 -maxitems 12; Write-Host ''; Read-Host '  Press Enter to return' | Out-Null }
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
            @{ Label = 'Re-scan now';              Key = 'R'; Hint = 'Refresh' },
            @{ Separator = $true },
            @{ Label = 'Back';                     Key = 'B'; Color = 'DarkGray' }
        )
        switch ($choice) {
            'S' { Repair-SystemFiles; $scan = Invoke-CoreScan; Read-Host '  Press Enter to continue' | Out-Null }
            'C' { Start-Process -FilePath 'chkdsk.exe' -ArgumentList 'C:', '/scan' -Wait -NoNewWindow; $scan = Invoke-CoreScan; Read-Host '  Press Enter to continue' | Out-Null }
            'W' { Restart-WindowsUpdateServices; $scan = Invoke-CoreScan; Read-Host '  Press Enter to continue' | Out-Null }
            'R' { $scan = Invoke-CoreScan; Read-Host '  Re-scan complete. Press Enter' | Out-Null }
            default { return $scan }
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

Start-WinPulseElevation -bootstrappath $bootstrapPath -bootstrapdefinition $bootstrapDefinition -bootstrapurl 'https://raw.githubusercontent.com/pokys/WinPulse/main/bootstrap.ps1'
Initialize-WinPulse

Write-Log -level 'INFO' -message 'Starting WinPulse core scan.'
$scan = Invoke-CoreScan
Show-WinPulseTriageMenu -scan $scan
