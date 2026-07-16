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
function Test-NoThrow([string]$Name, [scriptblock]$Action) {
    try { & $Action; Add-TestResult $Name $true 'No exception.' } catch { Add-TestResult $Name $false $_.Exception.Message }
}
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; Add-TestResult $Name $false 'No exception was thrown.' } catch { Add-TestResult $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}
function New-VersionFixture([string]$Root, [string]$Version) {
    $tauriDirectory = [System.IO.Path]::Combine($Root, 'src-tauri')
    $releaseDirectory = [System.IO.Path]::Combine($Root, 'release')
    [void][System.IO.Directory]::CreateDirectory($tauriDirectory)
    [void][System.IO.Directory]::CreateDirectory($releaseDirectory)
    $config = [ordered]@{ productName=$script:ProductName; mainBinaryName=$script:MainBinaryName; version=$Version; identifier=$script:AppIdentifier } | ConvertTo-Json
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($tauriDirectory, 'tauri.conf.json'), $config, (New-Object System.Text.UTF8Encoding($false)))
    $installerName = $script:ProductName + '_' + $Version + '_x64-setup.exe'
    $installerPath = [System.IO.Path]::Combine($releaseDirectory, $installerName)
    [System.IO.File]::WriteAllBytes($installerPath, [byte[]](1))
    $manifest = [ordered]@{ version=$Version; versionedInstallerFile=$installerName } | ConvertTo-Json
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($releaseDirectory, 'release-manifest.json'), $manifest, (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Root=$Root; ReleaseDirectory=$releaseDirectory; InstallerPath=$installerPath; Version=$Version }
}

$fixtureRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-version-path-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $stable = New-VersionFixture -Root ([System.IO.Path]::Combine($fixtureRoot, 'stable')) -Version '0.1.0'
    $stableContext = Resolve-DeskPetVersionContext -RepositoryRoot $stable.Root -ReleaseDirectory $stable.ReleaseDirectory -InstallerPath $stable.InstallerPath -ExplicitExpectedVersion $null
    Test-Equal 'Release actual version supports 0.1.0' '0.1.0' $stableContext.ExpectedVersion
    Test-NoThrow 'Registry version matching expected version is accepted' { Assert-DeskPetVersionContext -VersionContext $stableContext -RegistryVersions @('0.1.0') }

    $prereleaseVersion = -join @('0.1.0-beta.1', '-rc.1')
    $prerelease = New-VersionFixture -Root ([System.IO.Path]::Combine($fixtureRoot, 'prerelease')) -Version $prereleaseVersion
    $prereleaseContext = Resolve-DeskPetVersionContext -RepositoryRoot $prerelease.Root -ReleaseDirectory $prerelease.ReleaseDirectory -InstallerPath $prerelease.InstallerPath -ExplicitExpectedVersion $null
    Test-Equal 'Release actual version supports prerelease SemVer' $prereleaseVersion $prereleaseContext.ExpectedVersion
    Test-Throws 'Registry version mismatch reports all version sources' {
        Assert-DeskPetVersionContext -VersionContext $prereleaseContext -RegistryVersions @('0.1.0')
    } 'expected=.*registry=0\.1\.0.*installer=.*releaseManifest=.*tauri='

    $qaScripts = Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'windows')) -Filter *.ps1 -File
    $hardcodedHits = @($qaScripts | Select-String -Pattern ([regex]::Escape($prereleaseVersion)) -ErrorAction SilentlyContinue)
    Test-Equal 'QA scripts do not hardcode the discarded RC version' 0 $hardcodedHits.Count

    $installDirectory = [System.IO.Path]::Combine('C:\Program Files', $script:ProductName)
    $record = [pscustomobject]@{ DisplayName=$script:ProductName; DisplayVersion=$stableContext.ExpectedVersion; InstallLocation=$installDirectory; PSPath='Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Only' }
    $selection = Select-DeskPetInstallRecord -Records @($record) -ExpectedVersion $stableContext.ExpectedVersion -DirectoryExists { $true } -FileExists { $true }
    Test-Equal 'Only valid install record is not rejected by a stale default' $true ([bool]$selection.SelectedRecord)

    $callerBase = $script:RepositoryRoot
    $relativeOutput = '.\qa-results-current-machine-rebrand-resume'
    $expectedOutput = [System.IO.Path]::Combine($callerBase, 'qa-results-current-machine-rebrand-resume')
    $savedEnvironmentDirectory = [Environment]::CurrentDirectory
    try {
        [Environment]::CurrentDirectory = [Environment]::GetFolderPath('Desktop')
        Test-Equal 'Relative path uses caller directory when Environment.CurrentDirectory is Desktop' $expectedOutput (Resolve-CallerPath -Path $relativeOutput -BaseDirectory $callerBase)
        [Environment]::CurrentDirectory = [Environment]::GetFolderPath('System')
        Test-Equal 'Relative path uses caller directory when Environment.CurrentDirectory is System32' $expectedOutput (Resolve-CallerPath -Path $relativeOutput -BaseDirectory $callerBase)
    } finally {
        [Environment]::CurrentDirectory = $savedEnvironmentDirectory
    }
    $unicodeBase = [System.IO.Path]::Combine($fixtureRoot, $script:ProductName + ' QA')
    [void][System.IO.Directory]::CreateDirectory($unicodeBase)
    $resultDirectoryName = -join @([char]0x7ED3, [char]0x679C, ' ', [char]0x76EE, [char]0x5F55)
    Test-Equal 'Caller path supports Chinese and spaces' ([System.IO.Path]::Combine($unicodeBase, $resultDirectoryName)) (Resolve-CallerPath -Path ('.\' + $resultDirectoryName) -BaseDirectory $unicodeBase)

    $existingPlan = @(Get-DeskPetCurrentMachinePhasePlan -UseExistingInstallation)
    Test-Equal 'UseExistingInstallation does not contain installer execution' $false ($existingPlan -contains 'installation')
    Test-Equal 'UseExistingInstallation includes post-install validation' $true ($existingPlan -contains 'post-install-validation')
} finally {
    if ([System.IO.Directory]::Exists($fixtureRoot)) { [System.IO.Directory]::Delete($fixtureRoot, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
