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

    Write-Host ''
    Write-Host ('+------------------------------------------------------------+') -ForegroundColor DarkCyan
    Write-Host ('| {0,-58} |' -f $title) -ForegroundColor Cyan
    Write-Host ('+------------------------------------------------------------+') -ForegroundColor DarkCyan
}

function Show-WinPulseDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    Clear-Host
    Write-WinPulseHeader -title 'WinPulse Dashboard'
    Write-Host ('Generated: {0}' -f $scan.GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss'))

    $ramState = Get-WinPulseStateFromPercent -percent $scan.Hardware.Ram.UsedPercent
    $cDisk = $scan.Hardware.Disks | Where-Object { $_.Drive -eq 'C:' } | Select-Object -First 1
    $cDiskText = if ($cDisk) { ('{0}% free:{1}' -f $cDisk.UsedPercent, $cDisk.Free) } else { 'N/A' }
    Write-Status -label 'SYSTEM' -value ('{0} | {1} | up {2}' -f $scan.System.Hostname, $scan.System.WindowsVersion, $scan.System.Uptime) -state 'Info'
    $domainText = if ($scan.System.DomainJoined -and -not [string]::IsNullOrWhiteSpace($scan.System.Domain) -and $scan.System.Domain -ne 'Workgroup') { 'DJ {0}' -f $scan.System.Domain } else { 'Workgroup' }
    $platformState = if ($scan.System.Firmware -eq 'UEFI' -and $scan.Security.SecureBootState -eq 'Off') { 'Warning' } else { 'Info' }
    Write-Status -label 'PLATFORM' -value ('{0} | Boot {1} | SecureBoot {2}' -f $domainText, $scan.System.Firmware, $scan.Security.SecureBootState) -state $platformState
    Write-Status -label 'HARDWARE' -value ('RAM {0}% | C: {1} | SMART {2}' -f $scan.Hardware.Ram.UsedPercent, $cDiskText, $(if ($scan.Hardware.SmartHealthy) { 'OK' } else { 'FAIL' })) -state $ramState
    $avNames = @()
    if ($scan.Security.Antivirus -and $scan.Security.Antivirus.Products) {
        $avNames = @(
            $scan.Security.Antivirus.Products |
            ForEach-Object { $_.Name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
        )
    }
    $avLabel = if ($avNames.Count -gt 0) { $avNames -join ', ' } else { 'None detected' }
    $fwLabel = if ($scan.Security.FirewallEnabled) { 'ON' } else { 'OFF' }
    $bitLockerOn = $false
    if ($scan.Security.BitLocker -and $scan.Security.BitLocker.Count -gt 0) {
        $bitLockerOn = @($scan.Security.BitLocker | Where-Object { ([string]$_.ProtectionStatus) -match 'On|1' }).Count -gt 0
    }
    $blLabel = if ($bitLockerOn) { 'ON' } else { 'OFF' }
    $securityState = if ($scan.Security.Antivirus.EffectiveRealtimeProtection -and $scan.Security.FirewallEnabled) { 'OK' } else { 'Critical' }
    Write-Status -label 'SECURITY' -value ('AV {0} | FW {1} | BitLocker {2}' -f $avLabel, $fwLabel, $blLabel) -state $securityState
    Write-Status -label 'NETWORK' -value ('{0} | GW {1} | DNS {2} | Net {3}' -f $scan.Network.IPv4, $scan.Network.Gateway, ($scan.Network.DnsServers -join ','), $scan.Network.Internet) -state $(if ($scan.Network.Internet) { 'OK' } else { 'Warning' })
    Write-Status -label 'HEALTH' -value ('BSOD7 {0} | Crit24 {1} | RebootPending {2}' -f $scan.Health.BsodRecentCount, $scan.Health.CriticalLast24Hours, $scan.Health.PendingReboot) -state $(if ($scan.Health.CriticalLast24Hours -eq 0 -and -not $scan.Health.PendingReboot) { 'OK' } else { 'Warning' })
    Write-Host ''

    if ($scan.Errors.Count -gt 0) {
        Write-Host ''
        Write-Host '[SCAN WARNINGS]' -ForegroundColor Yellow
        foreach ($err in $scan.Errors) {
            Write-Host ('- {0}' -f $err) -ForegroundColor Yellow
        }
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

    try {
        $toolPath = Ensure-ToolInstalled -name 'CrystalDiskInfo'
        Start-Process -FilePath $toolPath
        return
    }
    catch {
        Write-Host ('CrystalDiskInfo download failed (MajorGeeks flow): {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Source page: https://www.majorgeeks.com/files/details/crystaldiskinfo_portable.html' -ForegroundColor DarkYellow
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
        Write-WinPulseHeader -title 'Office Menu'
        Write-Host '[1] Install (select version/edition, language CZ)'
        Write-Host '[2] Uninstall'
        Write-Host '[3] Repair'
        Write-Host '[0] Back'

        $choice = Read-Host 'Select action'
        switch ($choice) {
            '1' {
                try { Install-WinPulseOffice }
                catch {
                    Write-Host ("Office install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
            '2' {
                try { Uninstall-WinPulseOffice }
                catch {
                    Write-Host ("Office uninstall failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
            '3' {
                try { Repair-WinPulseOffice }
                catch {
                    Write-Host ("Office repair failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
            '0' { return }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
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
        Write-WinPulseHeader -title 'Stress Tests'
        Write-Host '[1/C] CPU stress test (60s)'
        Write-Host '[2/D] Disk stress test (512MB)'
        Write-Host '[3/R] RAM quick test'
        Write-Host '[4/M] Windows Memory Diagnostic (reboot)'
        Write-Host '[5/S] StressMyPC (portable)'
        Write-Host '[6/F] FurMark (advanced GPU)'
        Write-Host '[0/B] Back'

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'C') } { Invoke-WinPulseCpuStressTest -durationseconds 60 }
            { $_ -in @('2', 'D') } { Invoke-WinPulseDiskStressTest -sizemb 512 }
            { $_ -in @('3', 'R') } { Invoke-WinPulseRamQuickTest -durationseconds 20 }
            { $_ -in @('4', 'M') } { Start-WinPulseMemoryDiagnostic }
            { $_ -in @('5', 'S') } { Start-WinPulseStressMyPC }
            { $_ -in @('6', 'F') } { Start-WinPulseFurMarkAdvanced }
            { $_ -in @('0', 'B') } { return }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
        }

        Write-Host ''
        Read-Host 'Press Enter to continue' | Out-Null
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
        Write-WinPulseHeader -title 'External Tools'
        Write-Host '[1/A] Autoruns'
        Write-Host '[2/H] OpenHardwareMonitor'
        Write-Host '[3/B] BlueScreenView'
        Write-Host '[4/C] CrystalDiskInfo'
        Write-Host '[5/S] StressMyPC'
        Write-Host '[6/F] FurMark'
        Write-Host '[7/T] TechToolStore'
        Write-Host '[9/O] O&O ShutUp10++'
        Write-Host '[10/I] Process Explorer'
        Write-Host '[0/Q] Back'

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'A') } { Start-WinPulseAutoruns }
            { $_ -in @('2', 'H') } { Start-WinPulseOpenHardwareMonitor }
            { $_ -in @('3', 'B') } { Start-WinPulseBlueScreenView }
            { $_ -in @('4', 'C') } { Start-DeepDiskAnalysis }
            { $_ -in @('5', 'S') } { Start-WinPulseStressMyPC }
            { $_ -in @('6', 'F') } { Start-WinPulseFurMarkAdvanced }
            { $_ -in @('7', 'T') } { Start-WinPulseTechToolStore }
            { $_ -in @('9', 'O') } { Start-WinPulseOOShutUp }
            { $_ -in @('10', 'I') } { Start-WinPulseSysinternalsSuite }
            { $_ -in @('0', 'Q') } { return }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
        }

        Write-Host ''
        Read-Host 'Press Enter to continue' | Out-Null
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
        Write-WinPulseHeader -title 'Repairs (Guided)'
        Write-Host '[1/W] Show Windows Update errors (24h)'
        Write-Host '[2/P] List detected repair plans'
        Write-Host '[3/S] Safe actions (DISM/SFC, CHKDSK scan, WU services)'
        Write-Host '[0/B] Back'

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'W') } {
                $latestScan = Invoke-CoreScan
                Show-WindowsUpdateErrorDetails -scan $latestScan
                $scan = $latestScan
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('2', 'P') } {
                $plans = @(Get-WinPulseRepairPlans -scan $scan)
                if ($plans.Count -eq 0) {
                    Write-Host 'No repair plans detected for current state.' -ForegroundColor Green
                    Read-Host 'Press Enter to continue' | Out-Null
                    continue
                }

                Write-Host 'Detected plans:' -ForegroundColor Cyan
                for ($i = 0; $i -lt $plans.Count; $i++) {
                    $number = $i + 1
                    Write-Host ('[{0}] {1} - {2}' -f $number, $plans[$i].Label, $plans[$i].Reason)
                }
                Write-Host '[0] Back'
                $planChoice = (Read-Host 'Select plan').Trim()
                if ($planChoice -eq '0') {
                    continue
                }

                $index = 0
                if (-not [int]::TryParse($planChoice, [ref]$index)) {
                    Write-Host 'Invalid plan choice.' -ForegroundColor Yellow
                    Read-Host 'Press Enter to continue' | Out-Null
                    continue
                }

                $selected = $plans | Select-Object -Index ($index - 1) -ErrorAction SilentlyContinue
                if (-not $selected) {
                    Write-Host 'Invalid plan choice.' -ForegroundColor Yellow
                    Read-Host 'Press Enter to continue' | Out-Null
                    continue
                }

                $scan = Invoke-WinPulseGuidedRepair -scan $scan -planid $selected.Id
            }
            { $_ -in @('3', 'S') } {
                $scan = Show-WinPulseSafeActions -scan $scan
            }
            { $_ -in @('0', 'B') } { return $scan }
            default {
                Write-Host 'Invalid option.' -ForegroundColor Yellow
            }
        }
    }
}

function Show-WinPulseInstallMenu {
    [CmdletBinding()]
    param()

    if (-not (Test-WinGetAvailable)) {
        Write-Host 'Winget is not available on this system.' -ForegroundColor Red
        return
    }

    while ($true) {
        Clear-Host
        Write-WinPulseHeader -title 'Install / Apps Menu'
        Write-Host '[1/P] Preview Basic IT Set'
        Write-Host '[2/B] Install Basic IT Set'
        Write-Host '[3/C] Custom install (multi-select)'
        Write-Host '[4/U] Custom uninstall (multi-select)'
        Write-Host '[5/A] Update all apps'
        Write-Host '[6/O] Office menu (install/uninstall/repair)'
        Write-Host '[7/D] Dry run: Basic IT Set'
        Write-Host '[8/I] Dry run: Custom install'
        Write-Host '[9/N] Dry run: Custom uninstall'
        Write-Host '[0/Q] Back'

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'P') } {
                $preview = @(Get-WinPulsePackageCatalog | Where-Object { $_.InBasicSet })
                Write-WinPulseHeader -title 'Basic IT Set Preview'
                Show-WinPulsePackageTable -packages $preview
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('2', 'B') } { Install-BasicITSet; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('3', 'C') } { Invoke-WinPulseCustomInstall; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('4', 'U') } { Invoke-WinPulseCustomUninstall; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('5', 'A') } { Update-AllApplications; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('6', 'O') } { Show-WinPulseOfficeMenu; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('7', 'D') } { Install-BasicITSet -dryrun; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('8', 'I') } { Invoke-WinPulseCustomInstall -dryrun; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('9', 'N') } { Invoke-WinPulseCustomUninstall -dryrun; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('0', 'Q') } { return }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
        }
    }
}

function Show-WinPulseTweaksMenu {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-WinPulseHeader -title 'Tweaks'
    Write-Host 'Tweaks are intentionally disabled for now.' -ForegroundColor Yellow
    Write-Host 'Planned for later: curated safe tweaks with clear revert support.' -ForegroundColor DarkYellow
    Write-Host ''
    Read-Host 'Press Enter to return' | Out-Null
}

function Show-WinPulseNetworkMenu {
    [CmdletBinding()]
    param()

    Write-Host 'Network menu' -ForegroundColor Cyan
    Write-Host '[1] Full diagnostic'
    Write-Host '[2] Flush DNS'
    Write-Host '[3] Reset TCP/IP'
    Write-Host '[4] Reset Winsock'
    Write-Host '[5] Restart adapters'
    Write-Host '[6] Repair common network problems'
    Write-Host '[0] Back'

    $choice = Read-Host 'Select action'
    switch ($choice) {
        '1' { Invoke-NetworkDiagnostic | Format-List | Out-Host }
        '2' { Clear-NetworkDns }
        '3' { Reset-NetworkTcpIp }
        '4' { Reset-NetworkWinsock }
        '5' { Restart-NetworkAdapters }
        '6' { Repair-NetworkStack }
        default { }
    }
}

function Show-WinPulseSecurityMenu {
    [CmdletBinding()]
    param()

    Write-Host 'Security menu' -ForegroundColor Cyan
    Write-Host '[1] Run security assessment'
    Write-Host '[2] Check weak service configs'
    Write-Host '[3] Trigger BitLocker status overview'
    Write-Host '[0] Back'

    $choice = Read-Host 'Select action'
    switch ($choice) {
        '1' { Get-WinPulseSecurityAssessment | Format-List | Out-Host }
        '2' { Test-WeakServiceConfiguration | Format-Table -AutoSize | Out-Host }
        '3' { Get-BitLockerVolume | Format-Table MountPoint,ProtectionStatus,VolumeStatus -AutoSize | Out-Host }
        default { }
    }
}

function Show-WinPulseCleanupMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        Write-Host 'Cleanup menu' -ForegroundColor Cyan
        Write-Host '[1/A] Full artifact cleanup (WinPulse data/cache)'
        Write-Host '[2/L] Light cleanup (exports)'
        Write-Host '[3/F] Full remove WinPulse folder'
        Write-Host '[0/B] Back'

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'A') } { Invoke-WinPulseFullArtifactCleanup; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('2', 'L') } { Invoke-WinPulseLightCleanup; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('3', 'F') } { Remove-WinPulseCompletely; Read-Host 'Press Enter to continue' | Out-Null }
            { $_ -in @('0', 'B') } { return }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
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

function Show-WinPulseMainMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$scan
    )

    while ($true) {
        Show-WinPulseDashboard -scan $scan
        Write-WinPulseHeader -title 'Main Menu'
        Write-Host '  1. [D] Diagnostics' -ForegroundColor White
        Write-Host '  2. [I] Install / Apps' -ForegroundColor White
        Write-Host '  3. [R] Repairs (Guided)' -ForegroundColor White
        Write-Host '  4. [T] External Tools' -ForegroundColor White
        Write-Host '  5. [W] Tweaks' -ForegroundColor White
        Write-Host '  6. [C] Cleanup' -ForegroundColor White
        Write-Host '  7. [X] Export Scan JSON' -ForegroundColor White
        Write-Host '  0. [E] Exit' -ForegroundColor DarkGray

        $choice = (Read-Host 'Select an option').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'D') } {
                Invoke-WinPulseDiagnostics
                Write-Host ''
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('2', 'I') } { Show-WinPulseInstallMenu }
            { $_ -in @('3', 'R') } { $scan = Invoke-WinPulseRepairs -scan $scan }
            { $_ -in @('4', 'T') } { Show-WinPulseToolsMenu }
            { $_ -in @('5', 'W') } { Show-WinPulseTweaksMenu }
            { $_ -in @('6', 'C') } { Show-WinPulseCleanupMenu }
            { $_ -in @('7', 'X') } {
                $target = Join-Path $script:WinPulsePaths.Exports ('scan-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $scan | ConvertTo-Json -Depth 6 | Set-Content -Path $target -Encoding UTF8
                Write-Host ("Exported: {0}" -f $target) -ForegroundColor Green
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('0', 'E') } {
                Invoke-WinPulseExitCleanupPrompt
                return
            }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
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
        Write-WinPulseHeader -title 'Quick Triage'
        Write-Host '  1. [R] Re-scan' -ForegroundColor White
        Write-Host '  2. [L] Inspect logs (24h)' -ForegroundColor White
        Write-Host '  3. [S] Safe actions' -ForegroundColor White
        Write-Host '  4. [M] Full menu' -ForegroundColor White
        Write-Host '  0. [E] Exit' -ForegroundColor DarkGray

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'R') } { $scan = Invoke-CoreScan }
            { $_ -in @('2', 'L') } {
                Clear-Host
                Show-WinPulseEventLogInspection -hourback 24 -maxitems 12
                Write-Host ''
                Read-Host 'Press Enter to return' | Out-Null
            }
            { $_ -in @('3', 'S') } {
                $scan = Show-WinPulseSafeActions -scan $scan
            }
            { $_ -in @('4', 'M') } {
                Show-WinPulseMainMenu -scan $scan
                return
            }
            { $_ -in @('0', 'E') } {
                Invoke-WinPulseExitCleanupPrompt
                return
            }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
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
        Write-WinPulseHeader -title 'Safe Actions'
        Write-Host '[1/S] Run DISM + SFC'
        Write-Host '[2/C] Run CHKDSK C: /scan'
        Write-Host '[3/W] Restart Windows Update services'
        Write-Host '[4/R] Re-scan now'
        Write-Host '[0/B] Back'

        $choice = (Read-Host 'Select action').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('1', 'S') } {
                Repair-SystemFiles
                $scan = Invoke-CoreScan
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('2', 'C') } {
                Start-Process -FilePath 'chkdsk.exe' -ArgumentList 'C:', '/scan' -Wait -NoNewWindow
                $scan = Invoke-CoreScan
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('3', 'W') } {
                Restart-WindowsUpdateServices
                $scan = Invoke-CoreScan
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -in @('4', 'R') } {
                $scan = Invoke-CoreScan
                Read-Host 'Re-scan complete. Press Enter to continue' | Out-Null
            }
            { $_ -in @('0', 'B') } { return $scan }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
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
