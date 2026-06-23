#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'MigrationLive', 'W11Readiness', 'ExportBundle')]
    [string]$Mode = 'MigrationPreflight',

    [string]$BootstrapPath = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-SmokeIsAdmin {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Join-SmokePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$ChildPath
    )

    $result = $Path
    foreach ($child in $ChildPath) {
        $result = Join-Path -Path $result -ChildPath $child
    }
    return $result
}

function Convert-SmokeExtendedPath {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { return $Path }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $Path
    }

    if ($fullPath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
        return ('\\?\UNC\{0}' -f $fullPath.Substring(2))
    }

    return ('\\?\{0}' -f $fullPath)
}

function Remove-SmokeDirectoryTree {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        [System.IO.Directory]::Delete((Convert-SmokeExtendedPath -Path $Path), $true)
    }
    catch {
        if (Test-Path -LiteralPath $Path) {
            try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
}

function Convert-SmokeArgument {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    return ('"{0}"' -f (([string]$Value) -replace '"', '`"'))
}

function Invoke-SmokeChildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellPath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject][ordered]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

function Assert-SmokeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists((Convert-SmokeExtendedPath -Path $Path))) {
        throw ('Expected file missing: {0}' -f $Path)
    }
}

function Get-SmokeBootstrapFunctionText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($BootstrapPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw 'Could not parse bootstrap.ps1 for smoke helper assertions.'
    }

    $functionTexts = New-Object System.Collections.Generic.List[string]
    foreach ($functionName in @($Name)) {
        $functionAst = $ast.Find({
                param($node)
                return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName)
            }, $true)
        if (-not $functionAst) {
            throw ('{0} function not found.' -f $functionName)
        }
        [void]$functionTexts.Add($functionAst.Extent.Text)
    }

    return $functionTexts.ToArray()
}

function Assert-SmokeManifestCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$manifest.FailedCount -ne 0 -or [int]$manifest.MismatchCount -ne 0) {
        throw ('Manifest {0} has FailedCount={1}, MismatchCount={2}' -f $Path, $manifest.FailedCount, $manifest.MismatchCount)
    }
}

function Get-SmokeLatestVerifyRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RecordRoot
    )

    return Get-ChildItem -LiteralPath $RecordRoot -Filter 'migration-verify.json' -Recurse -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-SmokeLatestAppsRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RecordRoot
    )

    return Get-ChildItem -LiteralPath $RecordRoot -Filter 'migration-apps.json' -Recurse -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Invoke-SmokeDownloadVerificationAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPath
    )

    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeDownloadVerification-{0}' -f ([Guid]::NewGuid().ToString('N')))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

    try {
        foreach ($functionText in @(Get-SmokeBootstrapFunctionText -BootstrapPath $BootstrapPath -Name @('Test-WinPulseDownloadedBinary'))) {
            Invoke-Expression $functionText
        }

        $payloadPath = Join-Path -Path $tempRoot -ChildPath 'payload.bin'
        Set-Content -Path $payloadPath -Value 'WinPulse download verification smoke fixture' -Encoding ASCII
        $correctHash = (Get-FileHash -Path $payloadPath -Algorithm SHA256 -ErrorAction Stop).Hash

        $okHash = Test-WinPulseDownloadedBinary -path $payloadPath -sha256 $correctHash
        if (-not $okHash.Ok) {
            throw ('Correct SHA256 check failed: {0}' -f $okHash.Note)
        }

        $wrongHash = Test-WinPulseDownloadedBinary -path $payloadPath -sha256 ('0' * 64)
        if ($wrongHash.Ok) {
            throw 'Wrong SHA256 check unexpectedly passed.'
        }
        if ([string]$wrongHash.Note -notmatch 'SHA256 mismatch') {
            throw ('Wrong SHA256 check returned an unexpected note: {0}' -f $wrongHash.Note)
        }

        $unsignedExe = Join-Path -Path $tempRoot -ChildPath 'unsigned.exe'
        $className = 'WinPulseUnsigned' + ([Guid]::NewGuid().ToString('N'))
        $source = 'public class {0} {{ public static void Main() {{ }} }}' -f $className
        Add-Type -TypeDefinition $source -OutputAssembly $unsignedExe -OutputType ConsoleApplication -ErrorAction Stop
        $unsignedCheck = Test-WinPulseDownloadedBinary -path $unsignedExe -requireSignature $true
        if ($unsignedCheck.Ok) {
            throw 'Unsigned executable signature check unexpectedly passed.'
        }
        if ([string]$unsignedCheck.Note -notmatch 'NotSigned') {
            throw ('Unsigned executable signature note did not include NotSigned: {0}' -f $unsignedCheck.Note)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            try {
                $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot -ErrorAction Stop).Path
                $resolvedTemp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath()) -ErrorAction Stop).Path.TrimEnd('\')
                $tempPrefix = '{0}\' -f $resolvedTemp
                if ($resolvedTempRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-SmokeDirectoryTree -Path $resolvedTempRoot
                }
            }
            catch {
            }
        }
    }
}

function Invoke-SmokeLongPathEnumerationAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPath
    )

    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeLongPath-{0}' -f ([Guid]::NewGuid().ToString('N')))

    try {
        foreach ($functionText in @(Get-SmokeBootstrapFunctionText -BootstrapPath $BootstrapPath -Name @(
                    'Get-WinPulseExtendedPath',
                    'ConvertFrom-WinPulseExtendedPath',
                    'Get-WinPulseFilteredFiles',
                    'Measure-WinPulseFolderFiltered'
                ))) {
            Invoke-Expression $functionText
        }

        $root = Join-Path -Path $tempRoot -ChildPath 'root'
        $segments = @(
            'LongPathSegment0000000001',
            'LongPathSegment0000000002',
            'LongPathSegment0000000003',
            'LongPathSegment0000000004',
            'LongPathSegment0000000005',
            'LongPathSegment0000000006',
            'LongPathSegment0000000007',
            'LongPathSegment0000000008',
            'LongPathSegment0000000009',
            'LongPathSegment0000000010'
        )
        $deepDir = Join-SmokePath -Path $root -ChildPath $segments
        [System.IO.Directory]::CreateDirectory((Convert-SmokeExtendedPath -Path $deepDir)) | Out-Null
        $keepFile = Join-Path -Path $deepDir -ChildPath 'keep.txt'
        $skipFile = Join-Path -Path $deepDir -ChildPath 'skip.skip'
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path $keepFile), 'keep')
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path $skipFile), 'skip')

        $excludedDir = Join-Path -Path $deepDir -ChildPath 'excluded'
        [System.IO.Directory]::CreateDirectory((Convert-SmokeExtendedPath -Path $excludedDir)) | Out-Null
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path (Join-Path -Path $excludedDir -ChildPath 'hidden.txt')), 'hidden')

        if ($keepFile.Length -le 260) {
            throw 'Long-path enumeration fixture did not exceed 260 characters.'
        }

        $files = @(Get-WinPulseFilteredFiles -path $root -excludeFiles @('*.skip') -excludeDirs @('excluded'))
        if (@($files).Count -ne 1) {
            throw ('Long-path enumeration returned {0} files, expected 1.' -f @($files).Count)
        }
        if ([string]$files[0].Name -ne 'keep.txt') {
            throw ('Long-path enumeration returned the wrong file: {0}' -f $files[0].Name)
        }
        if ([string]$files[0].FullName -match '^\\\\\?\\') {
            throw 'Long-path enumeration returned an extended path for display.'
        }

        $measure = Measure-WinPulseFolderFiltered -path $root -excludeFiles @('*.skip') -excludeDirs @('excluded')
        if ([int]$measure.Files -ne 1 -or [double]$measure.Bytes -le 0) {
            throw ('Long-path filtered measurement returned Files={0}, Bytes={1}.' -f $measure.Files, $measure.Bytes)
        }
    }
    finally {
        Remove-SmokeDirectoryTree -Path $tempRoot
    }
}

function Invoke-SmokeCleanupLogicAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPath
    )

    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeCleanup-{0}' -f ([Guid]::NewGuid().ToString('N')))

    try {
        foreach ($functionText in @(Get-SmokeBootstrapFunctionText -BootstrapPath $BootstrapPath -Name @(
                    'ConvertTo-ReadableSize',
                    'Get-WinPulseExtendedPath',
                    'ConvertFrom-WinPulseExtendedPath',
                    'Get-WinPulseFilteredFiles',
                    'Measure-WinPulseFolderFiltered',
                    'New-WinPulseCleanupTarget',
                    'Get-WinPulseCleanupTargets',
                    'New-WinPulseCleanupPathItem',
                    'Resolve-WinPulseCleanupPathItems',
                    'Measure-WinPulseCleanupTarget',
                    'Get-WinPulseCleanupContentItems',
                    'Remove-WinPulseCleanupPathItem',
                    'Wait-WinPulseCleanupServiceStatus',
                    'Invoke-WinPulseCleanupSelected'
                ))) {
            Invoke-Expression $functionText
        }

        $fixtureTemp = Join-SmokePath -Path $tempRoot -ChildPath @('UserTemp')
        $fixtureNested = Join-SmokePath -Path $fixtureTemp -ChildPath @('nested')
        [System.IO.Directory]::CreateDirectory((Convert-SmokeExtendedPath -Path $fixtureNested)) | Out-Null
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path (Join-Path -Path $fixtureTemp -ChildPath 'a.tmp')), 'abc')
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path (Join-Path -Path $fixtureNested -ChildPath 'b.tmp')), '12345')

        $fixtureTarget = New-WinPulseCleanupTarget -key 'fixture' -label 'Fixture temp' -paths @($fixtureTemp) -mode 'contents'
        $fixtureMeasure = Measure-WinPulseCleanupTarget -target $fixtureTarget
        if ([int]$fixtureMeasure.Files -ne 2 -or [double]$fixtureMeasure.Bytes -ne 8) {
            throw ('Cleanup measurement returned Files={0}, Bytes={1}, expected 2/8.' -f $fixtureMeasure.Files, $fixtureMeasure.Bytes)
        }

        $windowsRoot = Join-SmokePath -Path $tempRoot -ChildPath @('Windows')
        $programData = Join-SmokePath -Path $tempRoot -ChildPath @('ProgramData')
        $localAppData = Join-SmokePath -Path $tempRoot -ChildPath @('LocalAppData')
        $appData = Join-SmokePath -Path $tempRoot -ChildPath @('AppData')
        foreach ($path in @($windowsRoot, $programData, $localAppData, $appData)) {
            [System.IO.Directory]::CreateDirectory((Convert-SmokeExtendedPath -Path $path)) | Out-Null
        }

        $targets = @(Get-WinPulseCleanupTargets -tempPath $fixtureTemp -windowsRoot $windowsRoot -programDataPath $programData -localAppDataPath $localAppData -appDataPath $appData)
        $keys = @($targets | ForEach-Object { $item = $_; [string]$item['Key'] })
        foreach ($requiredKey in @('usertemp', 'wintemp', 'recyclebin', 'wucache', 'deliveryopt', 'thumbcache', 'wer', 'cbslogs', 'prefetch', 'browsercache', 'memorydumps')) {
            if ($keys -notcontains $requiredKey) {
                throw ('Cleanup catalog did not include {0}.' -f $requiredKey)
            }
        }
        if ($keys -contains 'windowsold') {
            throw 'Cleanup catalog included windowsold even though the fixture path is absent.'
        }

        $userTempTarget = $targets | Where-Object { $item = $_; [string]$item['Key'] -eq 'usertemp' } | Select-Object -First 1
        $winTempTarget = $targets | Where-Object { $item = $_; [string]$item['Key'] -eq 'wintemp' } | Select-Object -First 1
        $recycleTarget = $targets | Where-Object { $item = $_; [string]$item['Key'] -eq 'recyclebin' } | Select-Object -First 1
        $wuTarget = $targets | Where-Object { $item = $_; [string]$item['Key'] -eq 'wucache' } | Select-Object -First 1
        if (-not [bool]$userTempTarget['PreTicked'] -or -not [bool]$winTempTarget['PreTicked'] -or -not [bool]$recycleTarget['PreTicked']) {
            throw 'Cleanup catalog did not pre-tick the expected safe defaults.'
        }
        if ([bool]$wuTarget['PreTicked']) {
            throw 'Cleanup catalog pre-ticked Windows Update cache unexpectedly.'
        }

        $deleteRoot = Join-SmokePath -Path $tempRoot -ChildPath @('DeleteOnly')
        [System.IO.Directory]::CreateDirectory((Convert-SmokeExtendedPath -Path $deleteRoot)) | Out-Null
        $deleteFile = Join-Path -Path $deleteRoot -ChildPath 'delete.tmp'
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path $deleteFile), 'delete me')
        $deleteTarget = New-WinPulseCleanupTarget -key 'deletefixture' -label 'Delete fixture' -paths @($deleteRoot) -mode 'contents'
        $deleteResult = @(Invoke-WinPulseCleanupSelected -targets @($deleteTarget)) | Select-Object -First 1
        if (-not $deleteResult -or [int]$deleteResult.ErrorCount -ne 0) {
            throw 'Cleanup temp deletion fixture reported an error.'
        }
        if ([System.IO.File]::Exists((Convert-SmokeExtendedPath -Path $deleteFile))) {
            throw 'Cleanup temp deletion fixture did not remove the temp file.'
        }
        if (-not [System.IO.Directory]::Exists((Convert-SmokeExtendedPath -Path $deleteRoot))) {
            throw 'Cleanup temp deletion fixture removed the container directory.'
        }
    }
    finally {
        Remove-SmokeDirectoryTree -Path $tempRoot
    }
}

function Invoke-SmokeDiagnosticsRenderAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPath
    )

    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeDiagnosticsRender-{0}' -f ([Guid]::NewGuid().ToString('N')))
    $capturedHostLines = New-Object System.Collections.Generic.List[string]

    function Clear-Host {
    }

    function Wait-WinPulseKey {
    }

    function Write-WinPulseHeader {
        param($title)
        [void]$capturedHostLines.Add(('HEADER: {0}' -f $title))
    }

    function Write-Host {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
            [object[]]$Object,

            [switch]$NoNewline,

            [object]$Separator = ' ',

            [ConsoleColor]$ForegroundColor,

            [ConsoleColor]$BackgroundColor
        )

        $parts = @()
        foreach ($item in @($Object)) {
            if ($null -ne $item) {
                $parts += [string]$item
            }
        }
        [void]$capturedHostLines.Add(($parts -join [string]$Separator))
    }

    function Select-WinPulseMenuItem {
        return $null
    }

    function Select-WinPulseMultiMenuItem {
        return $null
    }

    function Select-WinPulseFindingItem {
        return $null
    }

    function Show-WinPulsePagedTextBox {
        return $null
    }

    function New-SmokeDiagnosticsBaseScan {
        [CmdletBinding()]
        param()

        return [pscustomobject][ordered]@{
            GeneratedAt    = Get-Date
            System         = [ordered]@{
                Hostname       = 'SMOKE-PC'
                Model          = 'Smoke Model'
                Serial         = 'SMOKE123'
                WindowsVersion = 'Microsoft Windows 11 Pro (26100)'
                Uptime         = '1d 2h 3m'
                DomainJoined   = $false
                Domain         = 'Workgroup'
                Firmware       = 'UEFI'
                DumpInfo       = [ordered]@{
                    MinidumpCount  = 0
                    MinidumpNewest = $null
                    FullDumpExists = $false
                }
            }
            Hardware       = [ordered]@{
                Ram            = [ordered]@{
                    Total       = '16.00 GB'
                    Free        = '8.00 GB'
                    Used        = '8.00 GB'
                    UsedPercent = 50
                }
                Disks          = @()
                SmartHealthy   = $true
                CpuLoadPercent = $null
            }
            Security       = [ordered]@{
                Defender        = [ordered]@{
                    RealTimeProtection = $false
                    SignaturesUpToDate = $false
                }
                Antivirus       = [ordered]@{
                    Products                    = @()
                    ThirdPartyCount             = 0
                    EffectiveRealtimeProtection = $false
                }
                BitLocker      = @()
                FirewallEnabled = $true
                SecureBootState = 'On'
            }
            Health         = [ordered]@{
                BsodRecentCount              = 0
                WindowsUpdateErrorCount24Hours = 0
                WindowsUpdateRecentErrors    = @()
                WindowsUpdateCategoryCounts  = [ordered]@{
                    StoreApps     = 0
                    UpdateService = 0
                    Network       = 0
                    Servicing     = 0
                    AccessDenied  = 0
                    General       = 0
                }
                CriticalLast24Hours          = 0
                PendingReboot                = $false
            }
            Network        = [ordered]@{
                IPv4       = '192.0.2.10'
                Gateway    = '192.0.2.1'
                DnsServers = @('1.1.1.1', '8.8.8.8')
                Internet   = $true
            }
            HardwareDetail = [ordered]@{
                CPU         = [ordered]@{
                    Model       = 'Intel(R) Core(TM) i7-8650U CPU @ 1.90GHz'
                    Cores       = 4
                    Threads     = 8
                    BaseFreqMHz = 1900
                    Architecture = 'x64'
                }
                GPU         = @()
                DIMMs       = @()
                Battery     = [ordered]@{
                    Present              = $false
                    HealthPercent        = $null
                    CycleCount           = $null
                    DesignCapacityWh     = $null
                    FullChargeCapacityWh = $null
                    ChargePercent        = $null
                }
                Motherboard = [ordered]@{
                    Manufacturer = 'Smoke'
                    Model        = 'SmokeBoard'
                    BIOSVersion  = '1.0.0'
                    BIOSDate     = '2026-06-11'
                }
            }
            Temperatures   = [ordered]@{
                CPUTempCelsius = $null
                CPUTempSource  = 'Unavailable'
                DiskTemps      = @()
                Note           = 'Smoke fixture'
            }
            TPM            = [ordered]@{
                Present         = $true
                Enabled         = $true
                Version         = '2.0'
                Manufacturer    = 'SMK'
                Win11Compatible = $true
            }
            Drivers        = [ordered]@{
                Problematic     = @()
                ProblemDevices  = @()
                Unsigned        = @()
                RecentlyChanged = @()
            }
            Startup        = [ordered]@{
                RunKeyItems         = @()
                StartupFolderItems  = @()
                LogonScheduledTasks = @()
                FailedAutoServices  = @()
                LastBootTime        = $null
                BootDurationMs      = $null
            }
            UserAccounts   = $null
            NetworkDetail  = [ordered]@{
                Adapters         = @()
                WiFi             = $null
                ListeningPorts   = @()
                SMBShares        = @()
                VPNProfiles      = @()
                GatewayReachable = $false
            }
            Software       = $null
            Printers       = [ordered]@{
                Installed      = @()
                DefaultPrinter = 'N/A'
                StuckJobs      = @()
            }
            License        = [ordered]@{
                ActivationStatus  = 'Activated'
                LicenseType       = 'Retail'
                PartialProductKey = 'ABCDE'
                ExpiryDate        = $null
                ProductName       = 'Windows'
            }
            ScheduledTasks = $null
            Virtualization = $null
            DetailScanned  = $false
            Errors         = @()
        }
    }

    function Invoke-SmokeDiagnosticsRenderCase {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$Scan
        )

        $renderers = @(
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsFindings'; Action = { param($s) Show-WinPulseDiagnosticsFindings -scan $s } },
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsDrivers'; Action = { param($s) Show-WinPulseDiagnosticsDrivers -scan $s } },
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsServices'; Action = { param($s) Show-WinPulseDiagnosticsServices -scan $s } },
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsSystem'; Action = { param($s) Show-WinPulseDiagnosticsSystem -scan $s } },
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsHardware'; Action = { param($s) Show-WinPulseDiagnosticsHardware -scan $s } },
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsSecurity'; Action = { param($s) Show-WinPulseDiagnosticsSecurity -scan $s } },
            [pscustomobject][ordered]@{ Name = 'Show-WinPulseDiagnosticsNetwork'; Action = { param($s) Show-WinPulseDiagnosticsNetwork -scan $s } }
        )

        foreach ($renderer in @($renderers)) {
            $capturedHostLines.Clear()
            try {
                & $renderer.Action $Scan
            }
            catch {
                throw ('Diagnostics render assertion failed for scan "{0}" in {1}: {2}' -f $Name, $renderer.Name, $_.Exception.Message)
            }

            if ($Name -eq 'DataPresent' -and $renderer.Name -eq 'Show-WinPulseDiagnosticsSecurity') {
                $joinedOutput = @($capturedHostLines.ToArray()) -join "`n"
                if ($joinedOutput -notmatch 'ESET Endpoint Security') {
                    throw 'Diagnostics security render did not include the expected ESET Endpoint Security product.'
                }
            }
        }
    }

    try {
        $script:WinPulseBoxColor = 'Gray'
        $script:WinPulseServiceNoiselist = @(
            'DiagTrack', 'dmwappushservice', 'DoSvc',
            'edgeupdate', 'edgeupdatem',
            'gupdate', 'gupdatem',
            'MapsBroker', 'SCardSvr', 'sppsvc',
            'MozillaMaintenance', 'AdobeARMservice', 'Fax', 'WbioSrvc'
        )

        foreach ($functionText in @(Get-SmokeBootstrapFunctionText -BootstrapPath $BootstrapPath -Name @(
                    'Get-WinPulseTriageFindings',
                    'Get-WinPulseObjectValue',
                    'Get-WinPulseDiagnosticsCpuShort',
                    'Get-WinPulseStateFromPercent',
                    'ConvertTo-ReadableSize',
                    'Get-WinPulseFindingDetailTarget',
                    'Show-WinPulseFindingDetailTarget',
                    'Show-WinPulseDiagnosticsFindings',
                    'Show-WinPulseDiagnosticsDrivers',
                    'Show-WinPulseDiagnosticsServices',
                    'Show-WinPulseDiagnosticsSystem',
                    'Show-WinPulseDiagnosticsHardware',
                    'Show-WinPulseDiagnosticsSecurity',
                    'Show-WinPulseDiagnosticsNetwork'
                ))) {
            . ([scriptblock]::Create($functionText))
        }

        $emptyScan = New-SmokeDiagnosticsBaseScan

        $dataScan = New-SmokeDiagnosticsBaseScan
        $dataScan.Security['Antivirus']['Products'] = @(
            [pscustomobject][ordered]@{
                Name        = 'ESET Endpoint Security'
                IsMicrosoft = $false
            }
        )
        $dataScan.Security['Antivirus']['ThirdPartyCount'] = 1
        $dataScan.Security['Antivirus']['EffectiveRealtimeProtection'] = $true
        $dataScan.Security['BitLocker'] = @(
            [pscustomobject][ordered]@{
                MountPoint           = 'C:'
                ProtectionStatus     = 'On'
                EncryptionPercentage = 100
            }
        )
        $dataScan.Hardware['Disks'] = @(
            [pscustomobject][ordered]@{
                Drive       = 'C:'
                Size        = '256.00 GB'
                Free        = '20.00 GB'
                UsedPercent = 92
            }
        )
        $dataScan.HardwareDetail['DIMMs'] = @(
            [ordered]@{
                Slot         = 'DIMM0'
                Capacity     = '16.00 GB'
                SpeedMHz     = 3200
                Type         = 'DDR4'
                Manufacturer = 'Smoke'
            }
        )
        $dataScan.HardwareDetail['Battery'] = [ordered]@{
            Present              = $true
            HealthPercent        = 45
            CycleCount           = 700
            DesignCapacityWh     = 50
            FullChargeCapacityWh = 22.5
            ChargePercent        = 80
        }
        $dataScan.Temperatures['CPUTempCelsius'] = 72
        $dataScan.Temperatures['DiskTemps'] = @(
            [ordered]@{
                DiskModel   = 'Smoke SSD'
                TempCelsius = 38
                Source      = 'Smoke'
            }
        )
        $dataScan.Drivers['Problematic'] = @(
            [ordered]@{
                DeviceName       = 'PCI Smoke Device'
                ErrorCode        = 10
                ErrorDescription = 'Cannot start'
            }
        )
        $dataScan.Drivers['ProblemDevices'] = @('PCI\VEN_1234&DEV_5678')
        $dataScan.Drivers['Unsigned'] = @(
            [ordered]@{
                DeviceName     = 'Legacy Smoke Driver'
                DriverProvider = 'Smoke Vendor'
                InfName        = 'smoke.inf'
            }
        )
        $dataScan.Startup['FailedAutoServices'] = @(
            [ordered]@{
                Name        = 'SmokeSvc'
                DisplayName = 'Smoke Service'
                Status      = 'Stopped'
            }
        )

        $minimalScan = New-SmokeDiagnosticsBaseScan
        [void]$minimalScan.System.Remove('DumpInfo')
        [void]$minimalScan.Hardware.Remove('CpuLoadPercent')
        [void]$minimalScan.Security.Remove('Defender')
        [void]$minimalScan.Security.Remove('BitLocker')
        [void]$minimalScan.Security['Antivirus'].Remove('Products')
        [void]$minimalScan.Security['Antivirus'].Remove('ThirdPartyCount')
        $minimalScan.HardwareDetail = $null
        $minimalScan.Temperatures = $null
        $minimalScan.TPM = $null
        $minimalScan.Drivers = $null
        $minimalScan.Startup = $null
        $minimalScan.NetworkDetail = $null
        $minimalScan.Printers = $null
        $minimalScan.License = $null

        Invoke-SmokeDiagnosticsRenderCase -Name 'EmptyArrays' -Scan $emptyScan
        Invoke-SmokeDiagnosticsRenderCase -Name 'DataPresent' -Scan $dataScan
        Invoke-SmokeDiagnosticsRenderCase -Name 'MinimalMissingOptionalSubKeys' -Scan $minimalScan
        Microsoft.PowerShell.Utility\Write-Host 'Diagnostics render assertions: OK' -ForegroundColor Gray
    }
    finally {
        Remove-SmokeDirectoryTree -Path $tempRoot
    }
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($BootstrapPath)) {
    $BootstrapPath = Join-Path -Path $repoRoot -ChildPath 'bootstrap.ps1'
}

if (-not (Test-Path -LiteralPath $BootstrapPath)) {
    throw ("bootstrap.ps1 not found: {0}" -f $BootstrapPath)
}

$logRoot = Join-Path -Path $repoRoot -ChildPath 'smoke-logs'
if (-not (Test-Path -LiteralPath $logRoot)) {
    New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutPath = Join-Path -Path $logRoot -ChildPath ('WinPulse-Smoke-{0}-{1}.stdout.txt' -f $Mode, $stamp)
$stderrPath = Join-Path -Path $logRoot -ChildPath ('WinPulse-Smoke-{0}-{1}.stderr.txt' -f $Mode, $stamp)
$summaryPath = Join-Path -Path $logRoot -ChildPath ('WinPulse-Smoke-{0}-{1}.summary.txt' -f $Mode, $stamp)

Write-Host ('WinPulse smoke test: {0}' -f $Mode) -ForegroundColor Cyan
Write-Host ('Bootstrap: {0}' -f $BootstrapPath) -ForegroundColor Gray
Write-Host ('Logs: {0}' -f $logRoot) -ForegroundColor Gray

if (-not (Test-SmokeIsAdmin) -and $Mode -notin @('MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'MigrationLive')) {
    Write-Host ''
    Write-Host 'WARNING: run this smoke test from an elevated Windows PowerShell window.' -ForegroundColor Yellow
    Write-Host 'Parser errors will still be captured, but runtime output from auto-elevated child windows may not be captured.' -ForegroundColor Yellow
    Write-Host ''
}

$powershell = (Get-Command -Name powershell.exe -ErrorAction Stop).Source
# Bypass the soft startup gate so smoke child processes stay non-interactive.
$env:WINPULSE_ACCESS_GRANTED = '1'
# Suppress the startup update check so smoke runs never touch the network.
$env:WINPULSE_SKIP_UPDATE_CHECK = '1'
$start = Get-Date
$fixtureRoot = $null
$backupRoot = $null
$dryRunBackupRoot = $null
$skipAppListBackupRoot = $null
$appBackupRoot = $null
$restoreRoot = $null
$appRestoreRoot = $null
$remapRestoreRoot = $null
$restoreRecordPath = $null
$remapRestoreRecordPath = $null
$verifyRecordPath = $null
$driftVerifyRecordPath = $null
$appVerifyRecordPath = $null
$appsModeBackupRoot = $null
$appsModeRecordPath = $null
$appsModeMissingBackupRoot = $null
$lockedFixturePath = $null
$lockedFixtureStream = $null
$expectedFilesPresent = $false
$fixtureCleaned = $false
$processExitCode = 0
$stdoutParts = @()
$stderrParts = @()
$longDesktopSegments = @()
$longDesktopFileName = 'deep-file.txt'

try {
    Invoke-SmokeDownloadVerificationAssertions -BootstrapPath $BootstrapPath
    Invoke-SmokeLongPathEnumerationAssertions -BootstrapPath $BootstrapPath
    Invoke-SmokeCleanupLogicAssertions -BootstrapPath $BootstrapPath
    Invoke-SmokeDiagnosticsRenderAssertions -BootstrapPath $BootstrapPath

    if ($Mode -in @('MigrationBackup', 'MigrationRestore', 'MigrationVerify')) {
        $fixtureRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeFixture-{0}-{1}' -f $Mode, $stamp)
        $usersRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Users')
        $desktop = Join-SmokePath -Path $usersRoot -ChildPath @('tester', 'Desktop')
        $backupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Backup')
        $dryRunBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('BackupDryRun')
        $skipAppListBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('BackupSkipAppList')
        $appBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('AppBackup')
        $restoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Restore')
        $appRestoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('AppRestore')
        $remapRestoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('RestoreRemap')
        New-Item -Path $desktop -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path -Path $desktop -ChildPath 'sample.txt') -Value 'WinPulse smoke fixture' -Encoding ASCII
        $longDesktopSegments = @(
            'LongPathSegment0000000001',
            'LongPathSegment0000000002',
            'LongPathSegment0000000003',
            'LongPathSegment0000000004',
            'LongPathSegment0000000005',
            'LongPathSegment0000000006',
            'LongPathSegment0000000007',
            'LongPathSegment0000000008',
            'LongPathSegment0000000009',
            'LongPathSegment0000000010'
        )
        $longDesktopDirectory = Join-SmokePath -Path $desktop -ChildPath $longDesktopSegments
        [System.IO.Directory]::CreateDirectory((Convert-SmokeExtendedPath -Path $longDesktopDirectory)) | Out-Null
        $longDesktopFixtureFile = Join-Path -Path $longDesktopDirectory -ChildPath $longDesktopFileName
        [System.IO.File]::WriteAllText((Convert-SmokeExtendedPath -Path $longDesktopFixtureFile), 'WinPulse deep smoke fixture')
        if ($longDesktopFixtureFile.Length -le 260) {
            throw 'MigrationBackup long-path fixture did not exceed 260 characters.'
        }
        $chromeProfile = Join-SmokePath -Path $usersRoot -ChildPath @('tester', 'AppData', 'Local', 'Google', 'Chrome', 'User Data', 'Default')
        $firefoxProfile = Join-SmokePath -Path $usersRoot -ChildPath @('tester', 'AppData', 'Roaming', 'Mozilla', 'Firefox', 'Profiles', 'abc.default-release')
        $outlookRoot = Join-SmokePath -Path $usersRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook')
        $outlookRoamCache = Join-SmokePath -Path $outlookRoot -ChildPath @('RoamCache')
        New-Item -Path $chromeProfile -ItemType Directory -Force | Out-Null
        New-Item -Path $firefoxProfile -ItemType Directory -Force | Out-Null
        New-Item -Path $outlookRoamCache -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path -Path $chromeProfile -ChildPath 'Bookmarks') -Value 'chrome bookmarks' -Encoding ASCII
        Set-Content -Path (Join-Path -Path $firefoxProfile -ChildPath 'prefs.js') -Value 'firefox prefs' -Encoding ASCII
        Set-Content -Path (Join-Path -Path $outlookRoot -ChildPath 'test.pst') -Value 'pst data' -Encoding ASCII
        Set-Content -Path (Join-Path -Path $outlookRoamCache -ChildPath 'x.dat') -Value 'autocomplete' -Encoding ASCII
        Set-Content -Path (Join-Path -Path $outlookRoot -ChildPath 'big.ost') -Value 'ost cache' -Encoding ASCII

        $dryRunBackupArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', 'MigrationBackup',
            '-BackupProfilesRoot', (Convert-SmokeArgument -Value $usersRoot),
            '-BackupUsers', 'tester',
            '-BackupFolders', 'Desktop',
            '-BackupDestination', (Convert-SmokeArgument -Value $dryRunBackupRoot)
        )
        $dryRunBackupRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $dryRunBackupArguments
        $stdoutParts += $dryRunBackupRun.Stdout
        $stderrParts += $dryRunBackupRun.Stderr
        if ($dryRunBackupRun.ExitCode -ne 0) {
            throw ('MigrationBackup dry-run fixture exited with {0}' -f $dryRunBackupRun.ExitCode)
        }
        $dryRunAppsRoot = Join-Path -Path $dryRunBackupRoot -ChildPath 'apps'
        if (Test-Path -LiteralPath $dryRunAppsRoot) {
            throw 'MigrationBackup dry-run fixture wrote an apps sidecar folder.'
        }

        $lockedFixturePath = Join-Path -Path $desktop -ChildPath 'locked-copy.txt'
        Set-Content -Path $lockedFixturePath -Value 'locked smoke fixture' -Encoding ASCII
        $lockedFixtureStream = [System.IO.File]::Open($lockedFixturePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

        $backupArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', 'MigrationBackup',
            '-BackupProfilesRoot', (Convert-SmokeArgument -Value $usersRoot),
            '-BackupUsers', 'tester',
            '-BackupFolders', 'Desktop',
            '-BackupDestination', (Convert-SmokeArgument -Value $backupRoot),
            '-BackupExecute'
        )
        $backupRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $backupArguments
        $stdoutParts += $backupRun.Stdout
        $stderrParts += $backupRun.Stderr
        if ($backupRun.ExitCode -ne 0) {
            throw ('MigrationBackup fixture exited with {0}' -f $backupRun.ExitCode)
        }

        $manifestPath = Join-Path -Path $backupRoot -ChildPath 'manifest.json'
        Assert-SmokeFile -Path $manifestPath
        Assert-SmokeFile -Path (Join-Path -Path $backupRoot -ChildPath 'migration-backup-report.html')
        Assert-SmokeFile -Path (Join-Path -Path $backupRoot -ChildPath 'migration-backup-report.txt')
        Assert-SmokeFile -Path (Join-SmokePath -Path $backupRoot -ChildPath @('logs', 'migration-backup.log'))
        Assert-SmokeManifestCounts -Path $manifestPath
        $backupManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if (-not $backupManifest.PSObject.Properties['AppCapture'] -or -not $backupManifest.AppCapture) {
            throw 'MigrationBackup fixture did not record AppCapture.'
        }
        $installedAppsPath = Join-SmokePath -Path $backupRoot -ChildPath @('apps', 'installed-apps.json')
        Assert-SmokeFile -Path $installedAppsPath
        $null = Get-Content -LiteralPath $installedAppsPath -Raw | ConvertFrom-Json
        if ([string]$backupManifest.AppCapture.InventoryFile -ne 'apps\installed-apps.json') {
            throw 'MigrationBackup fixture did not record installed-apps.json in AppCapture.'
        }
        if ([bool]$backupManifest.AppCapture.WingetAvailable -and -not [string]::IsNullOrWhiteSpace([string]$backupManifest.AppCapture.WingetExportFile)) {
            $wingetExportPath = Join-SmokePath -Path $backupRoot -ChildPath @('apps', 'winget-packages.json')
            Assert-SmokeFile -Path $wingetExportPath
            $null = Get-Content -LiteralPath $wingetExportPath -Raw | ConvertFrom-Json
        }
        if (-not [bool]$backupManifest.AppCapture.WingetAvailable -and -not [string]::IsNullOrWhiteSpace([string]$backupManifest.AppCapture.WingetExportFile)) {
            throw 'MigrationBackup fixture recorded a winget export file while WingetAvailable was false.'
        }
        $lockedItem = $backupManifest.Items | Where-Object { $_.Folder -eq 'Desktop' } | Select-Object -First 1
        if (-not $lockedItem -or -not [bool]$lockedItem.Partial) {
            throw 'MigrationBackup locked-file fixture did not record a partial item.'
        }
        if (-not $lockedItem.PSObject.Properties['FailedEntryCount'] -or [int]$lockedItem.FailedEntryCount -lt 1) {
            throw 'MigrationBackup locked-file fixture did not record FailedEntryCount.'
        }
        $lockedEntriesText = (@($lockedItem.FailedEntries) -join "`n")
        if ($lockedEntriesText -notmatch 'locked-copy\.txt') {
            throw 'MigrationBackup locked-file fixture failed entries did not mention locked-copy.txt.'
        }
        $backupReportTextPath = Join-Path -Path $backupRoot -ChildPath 'migration-backup-report.txt'
        $backupReportHtmlPath = Join-Path -Path $backupRoot -ChildPath 'migration-backup-report.html'
        if ((Get-Content -LiteralPath $backupReportTextPath -Raw) -notmatch 'locked-copy\.txt') {
            throw 'MigrationBackup text report did not include the locked-file failed entry.'
        }
        if ((Get-Content -LiteralPath $backupReportHtmlPath -Raw) -notmatch 'locked-copy\.txt') {
            throw 'MigrationBackup HTML report did not include the locked-file failed entry.'
        }
        if ($lockedFixtureStream) {
            $lockedFixtureStream.Dispose()
            $lockedFixtureStream = $null
        }

        $skipAppListArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', 'MigrationBackup',
            '-BackupProfilesRoot', (Convert-SmokeArgument -Value $usersRoot),
            '-BackupUsers', 'tester',
            '-BackupFolders', 'Desktop',
            '-BackupDestination', (Convert-SmokeArgument -Value $skipAppListBackupRoot),
            '-BackupExecute',
            '-SkipBackupAppList'
        )
        $skipAppListRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $skipAppListArguments
        $stdoutParts += $skipAppListRun.Stdout
        $stderrParts += $skipAppListRun.Stderr
        if ($skipAppListRun.ExitCode -ne 0) {
            throw ('MigrationBackup SkipBackupAppList fixture exited with {0}' -f $skipAppListRun.ExitCode)
        }
        $skipManifestPath = Join-Path -Path $skipAppListBackupRoot -ChildPath 'manifest.json'
        Assert-SmokeFile -Path $skipManifestPath
        Assert-SmokeManifestCounts -Path $skipManifestPath
        $skipAppsRoot = Join-Path -Path $skipAppListBackupRoot -ChildPath 'apps'
        if (Test-Path -LiteralPath $skipAppsRoot) {
            throw 'MigrationBackup SkipBackupAppList fixture wrote an apps sidecar folder.'
        }
        $skipManifest = Get-Content -LiteralPath $skipManifestPath -Raw | ConvertFrom-Json
        if ($skipManifest.PSObject.Properties['AppCapture'] -and $null -ne $skipManifest.AppCapture) {
            throw 'MigrationBackup SkipBackupAppList fixture recorded AppCapture.'
        }
        $skipFailedItem = $skipManifest.Items | Where-Object { $_.PSObject.Properties['FailedEntryCount'] -and [int]$_.FailedEntryCount -ne 0 } | Select-Object -First 1
        if ($skipFailedItem) {
            throw 'MigrationBackup clean fixture recorded failed entries.'
        }
        $skipReportTextPath = Join-Path -Path $skipAppListBackupRoot -ChildPath 'migration-backup-report.txt'
        $skipReportHtmlPath = Join-Path -Path $skipAppListBackupRoot -ChildPath 'migration-backup-report.html'
        if ((Get-Content -LiteralPath $skipReportTextPath -Raw) -match 'failed copy entries') {
            throw 'MigrationBackup clean text report rendered a failed-entry section.'
        }
        if ((Get-Content -LiteralPath $skipReportHtmlPath -Raw) -match 'failed copy entries') {
            throw 'MigrationBackup clean HTML report rendered a failed-entry section.'
        }
        $skipLongBackupFile = Join-SmokePath -Path $skipAppListBackupRoot -ChildPath (@('tester', 'Desktop') + $longDesktopSegments + @($longDesktopFileName))
        Assert-SmokeFile -Path $skipLongBackupFile
        $skipDesktopItem = $skipManifest.Items | Where-Object { $_.Folder -eq 'Desktop' } | Select-Object -First 1
        if (-not $skipDesktopItem -or -not $skipDesktopItem.PSObject.Properties['Verification'] -or [string]$skipDesktopItem.Verification.Status -ne 'Verified') {
            throw 'MigrationBackup clean long-path fixture did not verify the Desktop item.'
        }
        $expectedFilesPresent = $true

        if ($Mode -eq 'MigrationVerify') {
            $verifyArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Convert-SmokeArgument -Value $BootstrapPath),
                '-Mode', 'MigrationVerify',
                '-VerifyBackupPath', (Convert-SmokeArgument -Value $backupRoot)
            )
            $verifyRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $verifyArguments
            $stdoutParts += $verifyRun.Stdout
            $stderrParts += $verifyRun.Stderr
            if ($verifyRun.ExitCode -ne 0) {
                throw ('MigrationVerify intact fixture exited with {0}' -f $verifyRun.ExitCode)
            }

            $verifyRecordRoot = Join-Path -Path $fixtureRoot -ChildPath '_WinPulseVerifyRecords'
            $verifyRecord = Get-SmokeLatestVerifyRecord -RecordRoot $verifyRecordRoot
            if (-not $verifyRecord) {
                throw 'MigrationVerify intact fixture did not write migration-verify.json.'
            }
            $verifyRecordPath = $verifyRecord.FullName
            Assert-SmokeFile -Path $verifyRecordPath
            Assert-SmokeFile -Path (Join-Path -Path $verifyRecord.DirectoryName -ChildPath 'migration-verify-report.html')
            Assert-SmokeFile -Path (Join-Path -Path $verifyRecord.DirectoryName -ChildPath 'migration-verify-report.txt')
            $verifyManifest = Get-Content -LiteralPath $verifyRecordPath -Raw | ConvertFrom-Json
            if ([int]$verifyManifest.DriftCount -ne 0 -or [int]$verifyManifest.IntactCount -lt 1) {
                throw ('MigrationVerify intact fixture reported IntactCount={0}, DriftCount={1}.' -f $verifyManifest.IntactCount, $verifyManifest.DriftCount)
            }

            $appBackupArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Convert-SmokeArgument -Value $BootstrapPath),
                '-Mode', 'MigrationBackup',
                '-BackupProfilesRoot', (Convert-SmokeArgument -Value $usersRoot),
                '-BackupUsers', 'tester',
                '-BackupApps', 'Chrome,Firefox,Outlook',
                '-BackupDestination', (Convert-SmokeArgument -Value $appBackupRoot),
                '-BackupExecute'
            )
            $appBackupRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $appBackupArguments
            $stdoutParts += $appBackupRun.Stdout
            $stderrParts += $appBackupRun.Stderr
            if ($appBackupRun.ExitCode -ne 0) {
                throw ('MigrationBackup app fixture exited with {0}' -f $appBackupRun.ExitCode)
            }

            $appManifestPath = Join-Path -Path $appBackupRoot -ChildPath 'manifest.json'
            Assert-SmokeFile -Path $appManifestPath
            Assert-SmokeManifestCounts -Path $appManifestPath
            Assert-SmokeFile -Path (Join-SmokePath -Path $appBackupRoot -ChildPath @('tester', 'AppData', 'Local', 'Google', 'Chrome', 'User Data', 'Default', 'Bookmarks'))
            Assert-SmokeFile -Path (Join-SmokePath -Path $appBackupRoot -ChildPath @('tester', 'AppData', 'Roaming', 'Mozilla', 'Firefox', 'Profiles', 'abc.default-release', 'prefs.js'))
            Assert-SmokeFile -Path (Join-SmokePath -Path $appBackupRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook', 'test.pst'))
            Assert-SmokeFile -Path (Join-SmokePath -Path $appBackupRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook', 'RoamCache', 'x.dat'))
            $backupOst = Join-SmokePath -Path $appBackupRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook', 'big.ost')
            if (Test-Path -LiteralPath $backupOst) {
                throw 'MigrationBackup app fixture copied an OST file.'
            }
            $appManifest = Get-Content -LiteralPath $appManifestPath -Raw | ConvertFrom-Json
            foreach ($expectedApp in @('chrome', 'firefox', 'outlook')) {
                if (@($appManifest.Apps) -notcontains $expectedApp) {
                    throw ('MigrationBackup app fixture did not record app key {0}.' -f $expectedApp)
                }
            }
            $appRelativeItem = $appManifest.Items | Where-Object { $_.AppKey -eq 'outlook' } | Select-Object -First 1
            if (-not $appRelativeItem -or [string]$appRelativeItem.Relative -ne 'AppData\Local\Microsoft\Outlook' -or @($appRelativeItem.ExtraExcludeFiles) -notcontains '*.ost') {
                throw 'MigrationBackup app fixture did not record Outlook Relative/ExtraExcludeFiles.'
            }

            $appRestoreArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Convert-SmokeArgument -Value $BootstrapPath),
                '-Mode', 'MigrationRestore',
                '-RestoreBackupPath', (Convert-SmokeArgument -Value $appBackupRoot),
                '-RestoreRoot', (Convert-SmokeArgument -Value $appRestoreRoot),
                '-RestoreExecute'
            )
            $appRestoreRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $appRestoreArguments
            $stdoutParts += $appRestoreRun.Stdout
            $stderrParts += $appRestoreRun.Stderr
            if ($appRestoreRun.ExitCode -ne 0) {
                throw ('MigrationRestore app fixture exited with {0}' -f $appRestoreRun.ExitCode)
            }

            Assert-SmokeFile -Path (Join-SmokePath -Path $appRestoreRoot -ChildPath @('tester', 'AppData', 'Local', 'Google', 'Chrome', 'User Data', 'Default', 'Bookmarks'))
            Assert-SmokeFile -Path (Join-SmokePath -Path $appRestoreRoot -ChildPath @('tester', 'AppData', 'Roaming', 'Mozilla', 'Firefox', 'Profiles', 'abc.default-release', 'prefs.js'))
            Assert-SmokeFile -Path (Join-SmokePath -Path $appRestoreRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook', 'test.pst'))
            Assert-SmokeFile -Path (Join-SmokePath -Path $appRestoreRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook', 'RoamCache', 'x.dat'))
            $restoreOst = Join-SmokePath -Path $appRestoreRoot -ChildPath @('tester', 'AppData', 'Local', 'Microsoft', 'Outlook', 'big.ost')
            if (Test-Path -LiteralPath $restoreOst) {
                throw 'MigrationRestore app fixture restored an OST file.'
            }

            $appVerifyArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Convert-SmokeArgument -Value $BootstrapPath),
                '-Mode', 'MigrationVerify',
                '-VerifyBackupPath', (Convert-SmokeArgument -Value $appBackupRoot)
            )
            $appVerifyRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $appVerifyArguments
            $stdoutParts += $appVerifyRun.Stdout
            $stderrParts += $appVerifyRun.Stderr
            if ($appVerifyRun.ExitCode -ne 0) {
                throw ('MigrationVerify app fixture exited with {0}' -f $appVerifyRun.ExitCode)
            }
            $appVerifyRecord = Get-SmokeLatestVerifyRecord -RecordRoot $verifyRecordRoot
            if (-not $appVerifyRecord) {
                throw 'MigrationVerify app fixture did not write migration-verify.json.'
            }
            $appVerifyRecordPath = $appVerifyRecord.FullName
            Assert-SmokeFile -Path (Join-Path -Path $appVerifyRecord.DirectoryName -ChildPath 'migration-verify-report.html')
            Assert-SmokeFile -Path (Join-Path -Path $appVerifyRecord.DirectoryName -ChildPath 'migration-verify-report.txt')
            $appVerifyManifest = Get-Content -LiteralPath $appVerifyRecordPath -Raw | ConvertFrom-Json
            if ([int]$appVerifyManifest.DriftCount -ne 0 -or [int]$appVerifyManifest.IntactCount -lt 3) {
                throw ('MigrationVerify app fixture reported IntactCount={0}, DriftCount={1}.' -f $appVerifyManifest.IntactCount, $appVerifyManifest.DriftCount)
            }

            $backupSample = Join-SmokePath -Path $backupRoot -ChildPath @('tester', 'Desktop', 'sample.txt')
            Remove-Item -LiteralPath $backupSample -Force -ErrorAction Stop

            $driftRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $verifyArguments
            $stdoutParts += $driftRun.Stdout
            $stderrParts += $driftRun.Stderr
            if ($driftRun.ExitCode -ne 0) {
                throw ('MigrationVerify drift fixture exited with {0}' -f $driftRun.ExitCode)
            }

            $driftRecord = Get-SmokeLatestVerifyRecord -RecordRoot $verifyRecordRoot
            if (-not $driftRecord) {
                throw 'MigrationVerify drift fixture did not write migration-verify.json.'
            }
            $driftVerifyRecordPath = $driftRecord.FullName
            Assert-SmokeFile -Path $driftVerifyRecordPath
            Assert-SmokeFile -Path (Join-Path -Path $driftRecord.DirectoryName -ChildPath 'migration-verify-report.html')
            Assert-SmokeFile -Path (Join-Path -Path $driftRecord.DirectoryName -ChildPath 'migration-verify-report.txt')
            $driftManifest = Get-Content -LiteralPath $driftVerifyRecordPath -Raw | ConvertFrom-Json
            if ([int]$driftManifest.DriftCount -lt 1) {
                throw ('MigrationVerify drift fixture reported DriftCount={0}.' -f $driftManifest.DriftCount)
            }
            $driftItem = $driftManifest.Items | Where-Object { $_.Status -eq 'Drift' } | Select-Object -First 1
            if (-not $driftItem) {
                throw 'MigrationVerify drift fixture did not record a Drift item.'
            }
        }

        if ($Mode -eq 'MigrationRestore') {
            $restoreArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Convert-SmokeArgument -Value $BootstrapPath),
                '-Mode', 'MigrationRestore',
                '-RestoreBackupPath', (Convert-SmokeArgument -Value $backupRoot),
                '-RestoreRoot', (Convert-SmokeArgument -Value $restoreRoot),
                '-RestoreFolders', 'Desktop',
                '-RestoreExecute'
            )
            $restoreRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $restoreArguments
            $stdoutParts += $restoreRun.Stdout
            $stderrParts += $restoreRun.Stderr
            if ($restoreRun.ExitCode -ne 0) {
                throw ('MigrationRestore fixture exited with {0}' -f $restoreRun.ExitCode)
            }

            Assert-SmokeFile -Path (Join-SmokePath -Path $restoreRoot -ChildPath @('tester', 'Desktop', 'sample.txt'))
            $record = Get-ChildItem -LiteralPath (Join-Path -Path $restoreRoot -ChildPath '_WinPulseRestoreRecords') -Filter 'migration-restore.json' -Recurse -ErrorAction Stop |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if (-not $record) {
                throw 'MigrationRestore fixture did not write migration-restore.json.'
            }
            $restoreRecordPath = $record.FullName
            Assert-SmokeFile -Path $restoreRecordPath
            Assert-SmokeFile -Path (Join-Path -Path $record.DirectoryName -ChildPath 'migration-restore-report.html')
            Assert-SmokeFile -Path (Join-Path -Path $record.DirectoryName -ChildPath 'migration-restore-report.txt')
            Assert-SmokeFile -Path (Join-SmokePath -Path $record.DirectoryName -ChildPath @('logs', 'migration-restore.log'))
            Assert-SmokeManifestCounts -Path $restoreRecordPath
            $restoreManifest = Get-Content -LiteralPath $restoreRecordPath -Raw | ConvertFrom-Json
            if ($restoreManifest.PSObject.Properties['RestoreAsUser']) {
                throw 'MigrationRestore fixture unexpectedly recorded RestoreAsUser without the parameter.'
            }
            $restoreItem = $restoreManifest.Items | Select-Object -First 1
            if (-not $restoreItem -or ([string]$restoreItem.Target).IndexOf('\tester\Desktop', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw 'MigrationRestore fixture target did not point at the original user.'
            }

            $remapRestoreArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Convert-SmokeArgument -Value $BootstrapPath),
                '-Mode', 'MigrationRestore',
                '-RestoreBackupPath', (Convert-SmokeArgument -Value $backupRoot),
                '-RestoreRoot', (Convert-SmokeArgument -Value $remapRestoreRoot),
                '-RestoreFolders', 'Desktop',
                '-RestoreAsUser', 'newuser',
                '-RestoreExecute'
            )
            $remapRestoreRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $remapRestoreArguments
            $stdoutParts += $remapRestoreRun.Stdout
            $stderrParts += $remapRestoreRun.Stderr
            if ($remapRestoreRun.ExitCode -ne 0) {
                throw ('MigrationRestore RestoreAsUser fixture exited with {0}' -f $remapRestoreRun.ExitCode)
            }

            Assert-SmokeFile -Path (Join-SmokePath -Path $remapRestoreRoot -ChildPath @('newuser', 'Desktop', 'sample.txt'))
            $oldRemapTarget = Join-SmokePath -Path $remapRestoreRoot -ChildPath @('tester', 'Desktop', 'sample.txt')
            if (Test-Path -LiteralPath $oldRemapTarget) {
                throw 'MigrationRestore RestoreAsUser fixture wrote to the original user.'
            }
            $remapRecord = Get-ChildItem -LiteralPath (Join-Path -Path $remapRestoreRoot -ChildPath '_WinPulseRestoreRecords') -Filter 'migration-restore.json' -Recurse -ErrorAction Stop |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if (-not $remapRecord) {
                throw 'MigrationRestore RestoreAsUser fixture did not write migration-restore.json.'
            }
            $remapRestoreRecordPath = $remapRecord.FullName
            Assert-SmokeFile -Path $remapRestoreRecordPath
            Assert-SmokeFile -Path (Join-Path -Path $remapRecord.DirectoryName -ChildPath 'migration-restore-report.html')
            Assert-SmokeFile -Path (Join-Path -Path $remapRecord.DirectoryName -ChildPath 'migration-restore-report.txt')
            Assert-SmokeFile -Path (Join-SmokePath -Path $remapRecord.DirectoryName -ChildPath @('logs', 'migration-restore.log'))
            Assert-SmokeManifestCounts -Path $remapRestoreRecordPath
            $remapManifest = Get-Content -LiteralPath $remapRestoreRecordPath -Raw | ConvertFrom-Json
            if (-not $remapManifest.PSObject.Properties['RestoreAsUser'] -or [string]$remapManifest.RestoreAsUser -ne 'newuser') {
                throw 'MigrationRestore RestoreAsUser fixture did not record RestoreAsUser=newuser.'
            }
            $remapItem = $remapManifest.Items | Select-Object -First 1
            if (-not $remapItem -or ([string]$remapItem.Target).IndexOf('\newuser\Desktop', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw 'MigrationRestore RestoreAsUser fixture manifest target did not point at newuser.'
            }
        }
    }
    elseif ($Mode -eq 'MigrationApps') {
        $fixtureRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeFixture-{0}-{1}' -f $Mode, $stamp)
        $appsModeBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('AppBackup')
        $appsModeMissingBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('MissingAppBackup')
        $appsFolder = Join-SmokePath -Path $appsModeBackupRoot -ChildPath @('apps')
        New-Item -Path $appsFolder -ItemType Directory -Force | Out-Null
        New-Item -Path $appsModeMissingBackupRoot -ItemType Directory -Force | Out-Null
        $wingetFixture = '{"Sources":[{"Packages":[{"PackageIdentifier":"Foo.Bar"},{"PackageIdentifier":"Baz.Qux"},{"PackageIdentifier":"Foo.Bar"}]}]}'
        Set-Content -Path (Join-Path -Path $appsFolder -ChildPath 'winget-packages.json') -Value $wingetFixture -Encoding ASCII

        $appsArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', 'MigrationApps',
            '-AppsBackupPath', (Convert-SmokeArgument -Value $appsModeBackupRoot)
        )
        $appsRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $appsArguments
        $stdoutParts += $appsRun.Stdout
        $stderrParts += $appsRun.Stderr
        if ($appsRun.ExitCode -ne 0) {
            throw ('MigrationApps dry-run fixture exited with {0}' -f $appsRun.ExitCode)
        }

        $appsRecordRoot = Join-Path -Path $fixtureRoot -ChildPath '_WinPulseAppRecords'
        $appsRecord = Get-SmokeLatestAppsRecord -RecordRoot $appsRecordRoot
        if (-not $appsRecord) {
            throw 'MigrationApps dry-run fixture did not write migration-apps.json.'
        }
        $appsModeRecordPath = $appsRecord.FullName
        Assert-SmokeFile -Path $appsModeRecordPath
        Assert-SmokeFile -Path (Join-Path -Path $appsRecord.DirectoryName -ChildPath 'migration-apps-report.html')
        Assert-SmokeFile -Path (Join-Path -Path $appsRecord.DirectoryName -ChildPath 'migration-apps-report.txt')
        $appsManifest = Get-Content -LiteralPath $appsModeRecordPath -Raw | ConvertFrom-Json
        if ($appsManifest.Tool.Action -ne 'DryRun') {
            throw ('MigrationApps fixture action was {0}, expected DryRun.' -f $appsManifest.Tool.Action)
        }
        if (-not $appsManifest.PSObject.Properties['AlreadyInstalledCount'] -or [int]$appsManifest.AlreadyInstalledCount -ne 0) {
            throw ('MigrationApps fixture AlreadyInstalledCount was {0}, expected 0.' -f $appsManifest.AlreadyInstalledCount)
        }
        if ([int]$appsManifest.SelectedCount -ne 2 -or [int]$appsManifest.DryRunCount -ne 2 -or [int]$appsManifest.FailedCount -ne 0 -or [int]$appsManifest.InstalledCount -ne 0) {
            throw ('MigrationApps fixture counts were Selected={0}, DryRun={1}, Installed={2}, Failed={3}.' -f $appsManifest.SelectedCount, $appsManifest.DryRunCount, $appsManifest.InstalledCount, $appsManifest.FailedCount)
        }
        foreach ($expectedId in @('Baz.Qux', 'Foo.Bar')) {
            $item = $appsManifest.Items | Where-Object { $_.PackageId -eq $expectedId } | Select-Object -First 1
            if (-not $item) {
                throw ('MigrationApps fixture did not record package {0}.' -f $expectedId)
            }
            if (-not [bool]$item.DryRun -or [string]$item.Note -notmatch 'not invoked') {
                throw ('MigrationApps fixture package {0} was not recorded as dry-run only.' -f $expectedId)
            }
            if ([string]$item.Command -notmatch '^winget install --id .+ -e --accept-package-agreements --accept-source-agreements$') {
                throw ('MigrationApps fixture command was not the expected winget install shape: {0}' -f $item.Command)
            }
        }

        $missingAppsArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', 'MigrationApps',
            '-AppsBackupPath', (Convert-SmokeArgument -Value $appsModeMissingBackupRoot)
        )
        $missingAppsRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $missingAppsArguments
        $stdoutParts += $missingAppsRun.Stdout
        $stderrParts += $missingAppsRun.Stderr
        if ($missingAppsRun.ExitCode -ne 0) {
            throw ('MigrationApps missing-export fixture exited with {0}' -f $missingAppsRun.ExitCode)
        }

        $expectedFilesPresent = $true
    }
    elseif ($Mode -eq 'MigrationLive') {
        $fixtureRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeFixture-{0}-{1}' -f $Mode, $stamp)
        $usersRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Users')
        $desktop = Join-SmokePath -Path $usersRoot -ChildPath @('tester', 'Desktop')
        $backupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('LiveBackup')
        $restoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('LiveRestore')
        New-Item -Path $desktop -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path -Path $desktop -ChildPath 'sample.txt') -Value 'WinPulse live migration smoke fixture' -Encoding ASCII

        $liveArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', 'MigrationLive',
            '-LiveSourceHost', 'SmokeHost',
            '-LiveUsers', 'tester',
            '-LiveFolders', 'Desktop',
            '-LiveDestination', (Convert-SmokeArgument -Value $backupRoot),
            '-LiveRestoreRoot', (Convert-SmokeArgument -Value $restoreRoot),
            '-_LiveProfilesRoot', (Convert-SmokeArgument -Value $usersRoot)
        )
        $liveRun = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $liveArguments
        $stdoutParts += $liveRun.Stdout
        $stderrParts += $liveRun.Stderr
        if ($liveRun.ExitCode -ne 0) {
            throw ('MigrationLive dry-run fixture exited with {0}' -f $liveRun.ExitCode)
        }
        if ([string]$liveRun.Stdout -notmatch 'Dry-run complete' -or [string]$liveRun.Stdout -notmatch 'Plan:') {
            throw 'MigrationLive dry-run fixture did not print the expected plan and dry-run summary.'
        }

        $liveManifestPath = Join-Path -Path $backupRoot -ChildPath 'manifest.json'
        Assert-SmokeFile -Path $liveManifestPath
        $liveManifest = Get-Content -LiteralPath $liveManifestPath -Raw | ConvertFrom-Json
        if ([string]$liveManifest.Tool.Action -ne 'DryRun') {
            throw ('MigrationLive fixture action was {0}, expected DryRun.' -f $liveManifest.Tool.Action)
        }
        if (@($liveManifest.Users) -notcontains 'tester' -or @($liveManifest.Folders) -notcontains 'Desktop') {
            throw 'MigrationLive fixture manifest did not record the selected user and folder.'
        }
        $liveCopiedFile = Join-SmokePath -Path $backupRoot -ChildPath @('tester', 'Desktop', 'sample.txt')
        if (Test-Path -LiteralPath $liveCopiedFile) {
            throw 'MigrationLive dry-run fixture copied a file.'
        }

        $expectedFilesPresent = $true
    }
    else {
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Convert-SmokeArgument -Value $BootstrapPath),
            '-Mode', $Mode
        )
        $run = Invoke-SmokeChildProcess -PowerShellPath $powershell -Arguments $arguments
        $stdoutParts += $run.Stdout
        $stderrParts += $run.Stderr
        $processExitCode = $run.ExitCode
    }
}
catch {
    $processExitCode = 1
    $stderrParts += $_.Exception.Message
}

if ($lockedFixtureStream) {
    try {
        $lockedFixtureStream.Dispose()
    }
    catch {
        $processExitCode = 1
        $stderrParts += ('Locked fixture cleanup failed: {0}' -f $_.Exception.Message)
    }
    $lockedFixtureStream = $null
}

if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
    try {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).Path
        $resolvedTemp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath()) -ErrorAction Stop).Path.TrimEnd('\')
        $tempPrefix = '{0}\' -f $resolvedTemp
        if ($resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-SmokeDirectoryTree -Path $resolvedFixture
            $fixtureCleaned = -not [System.IO.Directory]::Exists((Convert-SmokeExtendedPath -Path $resolvedFixture))
            if (-not $fixtureCleaned) {
                throw ('Fixture directory still exists after cleanup: {0}' -f $resolvedFixture)
            }
        }
        else {
            throw ('Refusing to remove fixture outside temp path: {0}' -f $resolvedFixture)
        }
    }
    catch {
        $processExitCode = 1
        $stderrParts += ('Fixture cleanup failed: {0}' -f $_.Exception.Message)
    }
}

Remove-Item Env:WINPULSE_ACCESS_GRANTED -ErrorAction SilentlyContinue
Remove-Item Env:WINPULSE_SKIP_UPDATE_CHECK -ErrorAction SilentlyContinue
$end = Get-Date

$stdout = @($stdoutParts) -join "`r`n"
$stderr = @($stderrParts) -join "`r`n"

$stdout | Set-Content -Path $stdoutPath -Encoding UTF8
$stderr | Set-Content -Path $stderrPath -Encoding UTF8

$latestExport = $null
if ($Mode -eq 'MigrationPreflight' -and (Test-Path -LiteralPath 'C:\ProgramData\WinPulse\exports')) {
    $latestExport = Get-ChildItem -Path 'C:\ProgramData\WinPulse\exports' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'MigrationPreflight-*' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latestExport) {
        $expected = @(
            Join-Path -Path $latestExport.FullName -ChildPath 'migration-preflight.json',
            Join-Path -Path $latestExport.FullName -ChildPath 'migration-preflight.html',
            Join-Path -Path $latestExport.FullName -ChildPath 'migration-preflight.txt',
            (Join-SmokePath -Path $latestExport.FullName -ChildPath @('logs', 'migration-preflight.log'))
        )
        $expectedFilesPresent = -not (@($expected | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0)
    }
}

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add(('Mode: {0}' -f $Mode))
$summary.Add(('Bootstrap: {0}' -f $BootstrapPath))
$summary.Add(('Start: {0}' -f $start.ToString('o')))
$summary.Add(('End: {0}' -f $end.ToString('o')))
$summary.Add(('ExitCode: {0}' -f $processExitCode))
$summary.Add(('Stdout: {0}' -f $stdoutPath))
$summary.Add(('Stderr: {0}' -f $stderrPath))
if ($latestExport) {
    $summary.Add(('LatestExport: {0}' -f $latestExport.FullName))
    $summary.Add(('ExpectedFilesPresent: {0}' -f $expectedFilesPresent))
}
if ($fixtureRoot) {
    $summary.Add(('FixtureRoot: {0}' -f $fixtureRoot))
    $summary.Add(('FixtureCleaned: {0}' -f $fixtureCleaned))
    $summary.Add(('BackupRoot: {0}' -f $backupRoot))
    if ($dryRunBackupRoot) { $summary.Add(('DryRunBackupRoot: {0}' -f $dryRunBackupRoot)) }
    if ($skipAppListBackupRoot) { $summary.Add(('SkipAppListBackupRoot: {0}' -f $skipAppListBackupRoot)) }
    if ($appBackupRoot) { $summary.Add(('AppBackupRoot: {0}' -f $appBackupRoot)) }
    if ($restoreRoot) { $summary.Add(('RestoreRoot: {0}' -f $restoreRoot)) }
    if ($appRestoreRoot) { $summary.Add(('AppRestoreRoot: {0}' -f $appRestoreRoot)) }
    if ($appsModeBackupRoot) { $summary.Add(('AppsModeBackupRoot: {0}' -f $appsModeBackupRoot)) }
    if ($appsModeMissingBackupRoot) { $summary.Add(('AppsModeMissingBackupRoot: {0}' -f $appsModeMissingBackupRoot)) }
    if ($remapRestoreRoot) { $summary.Add(('RemapRestoreRoot: {0}' -f $remapRestoreRoot)) }
    if ($restoreRecordPath) { $summary.Add(('RestoreRecord: {0}' -f $restoreRecordPath)) }
    if ($remapRestoreRecordPath) { $summary.Add(('RemapRestoreRecord: {0}' -f $remapRestoreRecordPath)) }
    if ($verifyRecordPath) { $summary.Add(('VerifyRecord: {0}' -f $verifyRecordPath)) }
    if ($appVerifyRecordPath) { $summary.Add(('AppVerifyRecord: {0}' -f $appVerifyRecordPath)) }
    if ($appsModeRecordPath) { $summary.Add(('AppsModeRecord: {0}' -f $appsModeRecordPath)) }
    if ($driftVerifyRecordPath) { $summary.Add(('DriftVerifyRecord: {0}' -f $driftVerifyRecordPath)) }
    $summary.Add(('ExpectedFilesPresent: {0}' -f $expectedFilesPresent))
}
$summary | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host ''
Write-Host ('Exit code: {0}' -f $processExitCode) -ForegroundColor $(if ($processExitCode -eq 0) { 'Green' } else { 'Red' })
Write-Host ('Summary: {0}' -f $summaryPath) -ForegroundColor Gray
Write-Host ('Stdout:  {0}' -f $stdoutPath) -ForegroundColor Gray
Write-Host ('Stderr:  {0}' -f $stderrPath) -ForegroundColor Gray

if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    Write-Host ''
    Write-Host 'stderr tail:' -ForegroundColor Red
    @($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 20) | ForEach-Object {
        Write-Host $_ -ForegroundColor Red
    }
}

if ($latestExport) {
    Write-Host ''
    Write-Host ('Latest export: {0}' -f $latestExport.FullName) -ForegroundColor Cyan
    Write-Host ('Expected files present: {0}' -f $expectedFilesPresent) -ForegroundColor $(if ($expectedFilesPresent) { 'Green' } else { 'Yellow' })
}

if ($fixtureRoot) {
    Write-Host ''
    Write-Host ('Fixture cleaned: {0}' -f $fixtureCleaned) -ForegroundColor $(if ($fixtureCleaned) { 'Green' } else { 'Yellow' })
    Write-Host ('Expected files present: {0}' -f $expectedFilesPresent) -ForegroundColor $(if ($expectedFilesPresent) { 'Green' } else { 'Yellow' })
}

if ($processExitCode -ne 0) {
    exit $processExitCode
}
