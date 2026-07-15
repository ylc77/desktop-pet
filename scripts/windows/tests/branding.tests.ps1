[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-TestResult $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}

$expectedProductName = -join @([char]0x4E03, [char]0x9171, [char]0x684C, [char]0x5BA0)
Test-Equal 'Windows PowerShell reads the Unicode product name' $expectedProductName $script:ProductName
Test-Equal 'Main binary name comes from Tauri config' 'desktop_pet' $script:MainBinaryName
Test-Equal 'Executable name includes the Windows suffix' 'desktop_pet.exe' $script:ExecutableName
Test-Equal 'Public installer name uses the product name' ($expectedProductName + '.exe') $script:PublicInstallerName
Test-Equal 'Identifier remains stable' 'dev.deskpet.framework' $script:AppIdentifier

$installDirectory = [System.IO.Path]::Combine('C:\Program Files', $script:ProductName)
$executablePath = [System.IO.Path]::Combine($installDirectory, $script:ExecutableName)
$installRecord = [pscustomobject]@{
    DisplayName=$script:ProductName; DisplayVersion='0.1.0'; InstallLocation=$installDirectory
    PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Current'
}
$installSelection = Select-DeskPetInstallRecord -Records @($installRecord) -ExpectedVersion '0.1.0' `
    -DirectoryExists { $true } -FileExists { param($Path) $Path -eq $executablePath }.GetNewClosure()
Test-Equal 'Install record matches the Unicode DisplayName' $executablePath $installSelection.ExecutablePath

$uninstaller = [System.IO.Path]::Combine($installDirectory, 'uninstall.exe')
$uninstallRecord = [pscustomobject]@{
    DisplayName=$script:ProductName; DisplayVersion='0.1.0'; QuietUninstallString=''
    UninstallString=('"' + $uninstaller + '"'); PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Current'
}
$uninstallSelection = Select-DeskPetUninstallRecord -Records @($uninstallRecord) -ExpectedVersion '0.1.0' -FileExists { $true }
Test-Equal 'Uninstall record matches the Unicode DisplayName' $uninstaller $uninstallSelection.Command.FilePath

$runValue = '"' + $executablePath + '"'
Test-Equal 'Autostart entry matches desktop_pet.exe' $true (Test-DeskPetRunEntryMatch -Name $script:ProductName -Value $runValue)
Test-Equal 'Legacy autostart is excluded by default' $false (Test-DeskPetRunEntryMatch -Name '' -Value ([string]$script:LegacyExecutableNames[0]))
Test-Equal 'Legacy autostart can be detected for cleanup' $true (Test-DeskPetRunEntryMatch -Name '' -Value ([string]$script:LegacyExecutableNames[0]) -IncludeLegacy)

$releaseDirectory = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-branding-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($releaseDirectory)
try {
    $legacyInstallerName = (-join @('Desk Pet', ' Framework', '_0.1.0_x64-setup.exe'))
    $legacyInstaller = [System.IO.Path]::Combine($releaseDirectory, $legacyInstallerName)
    $brandedInstallerName = $script:ProductName + '_0.1.0_x64-setup.exe'
    $brandedInstaller = [System.IO.Path]::Combine($releaseDirectory, $brandedInstallerName)
    [System.IO.File]::WriteAllBytes($legacyInstaller, [byte[]](1))
    [System.IO.File]::WriteAllBytes($brandedInstaller, [byte[]](2))
    $manifest = [ordered]@{ versionedInstallerFile=$brandedInstallerName } | ConvertTo-Json
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($releaseDirectory, 'release-manifest.json'), $manifest, (New-Object System.Text.UTF8Encoding($false)))
    $selectedInstaller = Get-DeskPetReleaseInstaller -ReleaseDirectory $releaseDirectory
    Test-Equal 'Release selection follows the branded manifest instead of an old installer' $brandedInstaller $selectedInstaller.FullName
} finally {
    if ([System.IO.Directory]::Exists($releaseDirectory)) { [System.IO.Directory]::Delete($releaseDirectory, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
