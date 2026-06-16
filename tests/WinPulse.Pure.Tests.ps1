#requires -version 5.1

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:BootstrapPath = Join-Path -Path $script:RepoRoot -ChildPath 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $script:BootstrapPath)) {
        throw ('bootstrap.ps1 not found at {0}' -f $script:BootstrapPath)
    }

    $script:WinPulsePaths = @{
        Root    = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulsePester'
        Exports = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulsePester\exports'
        Backups = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulsePester\backups'
        Tools   = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulsePester\tools'
        Logs    = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulsePester\logs'
    }

    $script:OriginalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    $script:OriginalUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
    $testCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $testCulture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $testCulture

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
            throw 'Could not parse bootstrap.ps1 for unit tests.'
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

    $functionNames = @(
        'ConvertTo-ReadableSize',
        'Get-WinPulseStateFromPercent',
        'Get-WinPulseObjectValue',
        'Get-WinPulseToolCatalog',
        'Get-WinPulseWingetExportPackageIds',
        'New-WinPulseWingetInstallCommandText',
        'Get-WinPulseRobocopyFailedEntries'
    )

    foreach ($functionText in @(Get-SmokeBootstrapFunctionText -BootstrapPath $script:BootstrapPath -Name $functionNames)) {
        Invoke-Expression $functionText
    }
}

AfterAll {
    if ($script:OriginalCulture) {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:OriginalCulture
    }
    if ($script:OriginalUICulture) {
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = $script:OriginalUICulture
    }
}

Describe 'ConvertTo-ReadableSize' {
    It 'formats bytes and binary unit boundaries with dot decimals' {
        ConvertTo-ReadableSize -bytes 0 | Should -Be '0 B'
        ConvertTo-ReadableSize -bytes 1536 | Should -Be '1.50 KB'
        ConvertTo-ReadableSize -bytes 1KB | Should -Be '1.00 KB'
        ConvertTo-ReadableSize -bytes 1MB | Should -Be '1.00 MB'
        ConvertTo-ReadableSize -bytes 1GB | Should -Be '1.00 GB'
        ConvertTo-ReadableSize -bytes 1TB | Should -Be '1.00 TB'
        ConvertTo-ReadableSize -bytes (2.5TB) | Should -Be '2.50 TB'
    }
}

Describe 'Get-WinPulseStateFromPercent' {
    It 'maps default thresholds to OK, Warning, and Critical' {
        Get-WinPulseStateFromPercent -percent 0 | Should -Be 'OK'
        Get-WinPulseStateFromPercent -percent 69.99 | Should -Be 'OK'
        Get-WinPulseStateFromPercent -percent 70 | Should -Be 'Warning'
        Get-WinPulseStateFromPercent -percent 89.99 | Should -Be 'Warning'
        Get-WinPulseStateFromPercent -percent 90 | Should -Be 'Critical'
        Get-WinPulseStateFromPercent -percent 100 | Should -Be 'Critical'
    }

    It 'supports inverse thresholds where low values are worse' {
        Get-WinPulseStateFromPercent -percent 5 -warning 30 -critical 10 -inverse | Should -Be 'Critical'
        Get-WinPulseStateFromPercent -percent 10 -warning 30 -critical 10 -inverse | Should -Be 'Critical'
        Get-WinPulseStateFromPercent -percent 20 -warning 30 -critical 10 -inverse | Should -Be 'Warning'
        Get-WinPulseStateFromPercent -percent 30 -warning 30 -critical 10 -inverse | Should -Be 'Warning'
        Get-WinPulseStateFromPercent -percent 31 -warning 30 -critical 10 -inverse | Should -Be 'OK'
    }
}

Describe 'Get-WinPulseObjectValue' {
    It 'reads existing and missing keys from ordered dictionaries' {
        $item = [ordered]@{
            Name = 'ESET'
            Count = 2
        }

        Get-WinPulseObjectValue -inputobject $item -name 'Name' | Should -Be 'ESET'
        Get-WinPulseObjectValue -inputobject $item -name 'Count' | Should -Be 2
        Get-WinPulseObjectValue -inputobject $item -name 'Missing' | Should -BeNullOrEmpty
    }

    It 'reads existing and missing properties from PSCustomObject values' {
        $item = [pscustomobject]@{
            Name = 'BitLocker'
            Count = 1
        }

        Get-WinPulseObjectValue -inputobject $item -name 'Name' | Should -Be 'BitLocker'
        Get-WinPulseObjectValue -inputobject $item -name 'Count' | Should -Be 1
        Get-WinPulseObjectValue -inputobject $item -name 'Missing' | Should -BeNullOrEmpty
    }
}

Describe 'Get-WinPulseToolCatalog' {
    It 'keeps every catalog entry addressable through dictionary keys' {
        $catalog = Get-WinPulseToolCatalog

        $catalog.Count | Should -BeGreaterThan 0
        foreach ($key in $catalog.Keys) {
            $tool = $catalog[$key]
            ($tool -is [System.Collections.IDictionary]) | Should -BeTrue

            ($tool.Contains('Urls') -or $tool.Contains('Url')) | Should -BeTrue
            if ($tool.Contains('Urls')) {
                $sources = @($tool['Urls'])
            }
            else {
                $sources = @($tool['Url'])
            }
            $sources.Count | Should -BeGreaterThan 0
            foreach ($source in $sources) {
                [string]::IsNullOrWhiteSpace([string]$source) | Should -BeFalse
            }

            ($tool.Contains('BinaryCandidates') -or $tool.Contains('Binary')) | Should -BeTrue
            if ($tool.Contains('BinaryCandidates')) {
                $binaries = @($tool['BinaryCandidates'])
            }
            else {
                $binaries = @($tool['Binary'])
            }
            $binaries.Count | Should -BeGreaterThan 0
            foreach ($binary in $binaries) {
                [string]::IsNullOrWhiteSpace([string]$binary) | Should -BeFalse
            }

            $tool.PSObject.Properties['Urls'] | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-WinPulseWingetExportPackageIds' {
    It 'returns sorted unique package ids from a normal export' {
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-winget-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        try {
            @'
{
  "Sources": [
    {
      "Packages": [
        { "PackageIdentifier": "Microsoft.PowerToys" },
        { "PackageIdentifier": "Git.Git" },
        { "PackageIdentifier": "git.git" },
        { "PackageIdentifier": "  VideoLAN.VLC  " },
        { "PackageIdentifier": "" }
      ]
    },
    {
      "Packages": [
        { "PackageIdentifier": "Mozilla.Firefox" }
      ]
    }
  ]
}
'@ | Set-Content -LiteralPath $path -Encoding ASCII

            $ids = @(Get-WinPulseWingetExportPackageIds -path $path)

            $ids.Count | Should -Be 4
            ($ids -join '|') | Should -Be 'Git.Git|Microsoft.PowerToys|Mozilla.Firefox|VideoLAN.VLC'
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty array when Sources or Packages are missing' {
        $missingSourcesPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-winget-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        $missingPackagesPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-winget-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        try {
            '{ "CreationDate": "2026-06-16T00:00:00Z" }' | Set-Content -LiteralPath $missingSourcesPath -Encoding ASCII
            '{ "Sources": [ { "SourceDetails": { "Name": "winget" } } ] }' | Set-Content -LiteralPath $missingPackagesPath -Encoding ASCII

            @(Get-WinPulseWingetExportPackageIds -path $missingSourcesPath).Count | Should -Be 0
            @(Get-WinPulseWingetExportPackageIds -path $missingPackagesPath).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $missingSourcesPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $missingPackagesPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty array for an empty or whitespace file' {
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-winget-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        try {
            "   `r`n`t " | Set-Content -LiteralPath $path -Encoding ASCII

            @(Get-WinPulseWingetExportPackageIds -path $path).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws for malformed JSON instead of returning garbage' {
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-winget-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        try {
            '{ "Sources": [ ' | Set-Content -LiteralPath $path -Encoding ASCII

            { Get-WinPulseWingetExportPackageIds -path $path } | Should -Throw
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'New-WinPulseWingetInstallCommandText' {
    It 'builds exact winget install commands for package ids' {
        New-WinPulseWingetInstallCommandText -packageId 'Git.Git' |
            Should -Be 'winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements'

        New-WinPulseWingetInstallCommandText -packageId 'Microsoft.PowerToys' |
            Should -Be 'winget install --id Microsoft.PowerToys -e --accept-package-agreements --accept-source-agreements'
    }
}

Describe 'Get-WinPulseRobocopyFailedEntries' {
    It 'extracts unique ERROR entries and their following detail lines' {
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-robocopy-{0}.log' -f ([guid]::NewGuid().ToString('N')))
        try {
            @'
-------------------------------------------------------------------------------
2026/06/16 10:00:00 ERROR 5 (0x00000005) Copying File C:\Source\locked.txt
Access is denied.
2026/06/16 10:00:01 ERROR 123 (0x0000007B) Copying File C:\Source\badname.txt
The filename, directory name, or volume label syntax is incorrect.
2026/06/16 10:00:02 ERROR 5 (0x00000005) Copying File C:\Source\locked.txt
Access is denied.
'@ | Set-Content -LiteralPath $path -Encoding ASCII

            $entries = @(Get-WinPulseRobocopyFailedEntries -logPath $path)

            $entries.Count | Should -Be 2
            $entries[0] | Should -Be 'ERROR 5: Copying File C:\Source\locked.txt - Access is denied.'
            $entries[1] | Should -Be 'ERROR 123: Copying File C:\Source\badname.txt - The filename, directory name, or volume label syntax is incorrect.'
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty array for clean or missing logs' {
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('WinPulse-robocopy-{0}.log' -f ([guid]::NewGuid().ToString('N')))
        try {
            @'
-------------------------------------------------------------------------------
               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Files :        10        10         0         0         0         0
'@ | Set-Content -LiteralPath $path -Encoding ASCII

            @(Get-WinPulseRobocopyFailedEntries -logPath $path).Count | Should -Be 0
            @(Get-WinPulseRobocopyFailedEntries -logPath (Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'WinPulse-missing.log')).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}
