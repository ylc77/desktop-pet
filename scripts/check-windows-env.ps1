[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\windows\common.ps1"
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Name, [bool]$Passed, [string]$Details, [bool]$Required = $true) {
    $results.Add([pscustomobject]@{ Check = $Name; Status = $(if ($Passed) { 'PASS' } elseif ($Required) { 'FAIL' } else { 'WARN' }); Details = $Details; Required = $Required })
}

function Test-Command([string]$Name, [string[]]$Arguments = @('--version')) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { Add-Result $Name $false "$Name is not available on PATH."; return }
    try { $version = (& $command.Source @Arguments 2>&1 | Select-Object -First 1); Add-Result $Name $true ([string]$version) }
    catch { Add-Result $Name $false $_.Exception.Message }
}

Test-Command pwsh
Test-Command node
Test-Command npm
Test-Command rustc
Test-Command cargo
Test-Command rustup @('show', 'active-toolchain')

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$cargoBin = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cargo\bin'
$cargoOnUserPath = @($userPath -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') }) -contains $cargoBin.TrimEnd('\')
Add-Result 'User PATH contains Cargo' $cargoOnUserPath $(if ($cargoOnUserPath) { '%USERPROFILE%\.cargo\bin is present.' } else { 'Cargo is available to this process, but add %USERPROFILE%\.cargo\bin to the user PATH for future terminals.' }) $false

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$msvcPath = $null
if (Test-Path -LiteralPath $vswhere) {
    $msvcPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
Add-Result 'Visual Studio C++ Build Tools' ([bool]$msvcPath) $(if ($msvcPath) { 'MSVC x64 toolchain detected by vswhere.' } else { 'Install Visual Studio Build Tools with Desktop development with C++.' })

$sdkRoots = @(
    (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10 -ErrorAction SilentlyContinue),
    (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10 -ErrorAction SilentlyContinue)
) | Where-Object { $_ }
Add-Result 'Windows SDK' ($sdkRoots.Count -gt 0) $(if ($sdkRoots.Count) { 'Windows 10/11 SDK registry entry detected.' } else { 'Install a Windows 10 or Windows 11 SDK.' })

$webViewClient = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$webViewKeys = @(
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$webViewClient",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$webViewClient",
    "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$webViewClient"
)
$webViewVersion = $webViewKeys | ForEach-Object { Get-ItemPropertyValue -Path $_ -Name pv -ErrorAction SilentlyContinue } | Where-Object { $_ } | Select-Object -First 1
Add-Result 'WebView2 Runtime' ([bool]$webViewVersion) $(if ($webViewVersion) { "Evergreen Runtime $webViewVersion" } else { 'Runtime not found in EdgeUpdate registry; installed app startup requires WebView2.' }) $false

$nativeArchitecture = Get-NativeProcessorArchitecture
$processArchitecture = Get-CurrentProcessArchitecture
Add-Result 'Architecture detection' (-not [string]::IsNullOrWhiteSpace($nativeArchitecture) -and -not [string]::IsNullOrWhiteSpace($processArchitecture)) "Native=$nativeArchitecture; OS64=$([Environment]::Is64BitOperatingSystem); Process=$processArchitecture; Process64=$([Environment]::Is64BitProcess)"
Add-Result 'Required environment variables' ([bool]$env:PATH -and [bool]$env:USERPROFILE) 'PATH and USERPROFILE are defined.'

$results | Format-Table -AutoSize
if ($results.Where({ $_.Required -and $_.Status -eq 'FAIL' }).Count -gt 0) { exit 1 }
exit 0
