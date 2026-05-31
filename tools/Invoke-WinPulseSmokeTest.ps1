#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('MigrationPreflight', 'MigrationBackup', 'MigrationRestore', 'W11Readiness', 'ExportBundle')]
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

if (-not (Test-SmokeIsAdmin)) {
    Write-Host ''
    Write-Host 'WARNING: run this smoke test from an elevated Windows PowerShell window.' -ForegroundColor Yellow
    Write-Host 'Parser errors will still be captured, but runtime output from auto-elevated child windows may not be captured.' -ForegroundColor Yellow
    Write-Host ''
}

$powershell = (Get-Command -Name powershell.exe -ErrorAction Stop).Source
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $BootstrapPath),
    '-Mode', $Mode
) -join ' '

$start = Get-Date
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $powershell
$psi.Arguments = $arguments
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
$end = Get-Date

$stdout | Set-Content -Path $stdoutPath -Encoding UTF8
$stderr | Set-Content -Path $stderrPath -Encoding UTF8

$latestExport = $null
$expectedFilesPresent = $false
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
$summary.Add(('ExitCode: {0}' -f $process.ExitCode))
$summary.Add(('Stdout: {0}' -f $stdoutPath))
$summary.Add(('Stderr: {0}' -f $stderrPath))
if ($latestExport) {
    $summary.Add(('LatestExport: {0}' -f $latestExport.FullName))
    $summary.Add(('ExpectedFilesPresent: {0}' -f $expectedFilesPresent))
}
$summary | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host ''
Write-Host ('Exit code: {0}' -f $process.ExitCode) -ForegroundColor $(if ($process.ExitCode -eq 0) { 'Green' } else { 'Red' })
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

if ($process.ExitCode -ne 0) {
    exit $process.ExitCode
}
