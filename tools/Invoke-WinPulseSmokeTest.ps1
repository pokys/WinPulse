#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps', 'W11Readiness', 'ExportBundle')]
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

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ('Expected file missing: {0}' -f $Path)
    }
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

if (-not (Test-SmokeIsAdmin) -and $Mode -notin @('MigrationBackup', 'MigrationRestore', 'MigrationVerify', 'MigrationApps')) {
    Write-Host ''
    Write-Host 'WARNING: run this smoke test from an elevated Windows PowerShell window.' -ForegroundColor Yellow
    Write-Host 'Parser errors will still be captured, but runtime output from auto-elevated child windows may not be captured.' -ForegroundColor Yellow
    Write-Host ''
}

$powershell = (Get-Command -Name powershell.exe -ErrorAction Stop).Source
$start = Get-Date
$fixtureRoot = $null
$backupRoot = $null
$dryRunBackupRoot = $null
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
$expectedFilesPresent = $false
$fixtureCleaned = $false
$processExitCode = 0
$stdoutParts = @()
$stderrParts = @()

try {
    if ($Mode -in @('MigrationBackup', 'MigrationRestore', 'MigrationVerify')) {
        $fixtureRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-SmokeFixture-{0}-{1}' -f $Mode, $stamp)
        $usersRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Users')
        $desktop = Join-SmokePath -Path $usersRoot -ChildPath @('tester', 'Desktop')
        $backupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Backup')
        $dryRunBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('BackupDryRun')
        $appBackupRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('AppBackup')
        $restoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('Restore')
        $appRestoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('AppRestore')
        $remapRestoreRoot = Join-SmokePath -Path $fixtureRoot -ChildPath @('RestoreRemap')
        New-Item -Path $desktop -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path -Path $desktop -ChildPath 'sample.txt') -Value 'WinPulse smoke fixture' -Encoding ASCII
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
        $appsManifest = Get-Content -LiteralPath $appsModeRecordPath -Raw | ConvertFrom-Json
        if ($appsManifest.Tool.Action -ne 'DryRun') {
            throw ('MigrationApps fixture action was {0}, expected DryRun.' -f $appsManifest.Tool.Action)
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

if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
    try {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).Path
        $resolvedTemp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath()) -ErrorAction Stop).Path.TrimEnd('\')
        $tempPrefix = '{0}\' -f $resolvedTemp
        if ($resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction Stop
            $fixtureCleaned = $true
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
