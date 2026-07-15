[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Test-ArchitectureCase([string]$Name, [string]$Expected, [scriptblock]$Action) {
    $actual = & $Action
    $script:results += [pscustomobject]@{ Name=$Name; Expected=$Expected; Actual=$actual; Passed=$actual -eq $Expected }
}

$savedW6432 = $env:PROCESSOR_ARCHITEW6432
$savedArchitecture = $env:PROCESSOR_ARCHITECTURE
try {
    $env:PROCESSOR_ARCHITEW6432 = $null
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    Test-ArchitectureCase 'AMD64 normalizes to x64' 'x64' { Get-NativeProcessorArchitecture }

    $env:PROCESSOR_ARCHITECTURE = 'x86'
    Test-ArchitectureCase 'x86 remains x86' 'x86' { Get-NativeProcessorArchitecture }

    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    Test-ArchitectureCase 'ARM64 normalizes to arm64' 'arm64' { Get-NativeProcessorArchitecture }

    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    Test-ArchitectureCase 'PROCESSOR_ARCHITEW6432 takes precedence' 'arm64' { Get-NativeProcessorArchitecture }

    $env:PROCESSOR_ARCHITEW6432 = $null
    $env:PROCESSOR_ARCHITECTURE = $null
    Test-ArchitectureCase 'Missing variables fall back to 64-bit OS' 'x64' { Get-NativeProcessorArchitecture -Is64BitOperatingSystem $true }
    Test-ArchitectureCase 'Missing variables fall back to 32-bit OS' 'x86' { Get-NativeProcessorArchitecture -Is64BitOperatingSystem $false }
} finally {
    $env:PROCESSOR_ARCHITEW6432 = $savedW6432
    $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
}

$results | Format-Table -AutoSize
$versionPassed = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Expected='5.1'; Actual=$PSVersionTable.PSVersion.ToString(); Passed=$versionPassed } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $versionPassed) { exit 1 }
