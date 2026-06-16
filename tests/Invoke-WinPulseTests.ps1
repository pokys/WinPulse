#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Path $PSCommandPath -Parent
if ([string]::IsNullOrWhiteSpace($testsRoot)) {
    $testsRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

$pesterModule = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pesterModule) {
    Write-Host 'Pester 5.x is required to run WinPulse unit tests.' -ForegroundColor Red
    Write-Host 'Install-Module -Name Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck'
    exit 1
}

Import-Module -Name $pesterModule.Path -Force

$configuration = New-PesterConfiguration
$configuration.Run.Path = @(Join-Path -Path $testsRoot -ChildPath 'WinPulse.Pure.Tests.ps1')
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $false

$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0) {
    exit 1
}

exit 0
