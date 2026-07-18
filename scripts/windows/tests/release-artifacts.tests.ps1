[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Add-Test([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Write-Utf8NoBom([string]$Path, [string]$Value) {
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-ReleaseVerification([string]$ReleaseDirectory) {
    $scriptPath = [System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'windows', 'verify-release-artifacts.ps1')
    $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ReleaseDirectory $ReleaseDirectory 2>&1 | Out-String)
    [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=$output }
}

$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-release-artifacts-' + [guid]::NewGuid().ToString('N'))
try {
    $release = [System.IO.Path]::Combine($root, 'release with 中文')
    $updaterRoot = [System.IO.Path]::Combine($release, 'updater')
    $historicalVersion = '0.1.2-beta.2'
    $historicalDirectory = [System.IO.Path]::Combine($updaterRoot, $historicalVersion)
    [void][System.IO.Directory]::CreateDirectory($historicalDirectory)

    $version = Get-DeskPetReleaseVersion -RepositoryRoot $script:RepositoryRoot
    $versionedName = "$script:ProductName`_$version`_x64-setup.exe"
    $versionedPath = [System.IO.Path]::Combine($release, $versionedName)
    $publicPath = [System.IO.Path]::Combine($release, $script:PublicInstallerName)
    [System.IO.File]::WriteAllBytes($versionedPath, [byte[]](1,3,3,7))
    [System.IO.File]::Copy($versionedPath, $publicPath)
    $hash = (Get-FileHash -LiteralPath $versionedPath -Algorithm SHA256).Hash
    $head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
    $manifest = [ordered]@{
        applicationName=$script:ProductName; version=$version; architecture='x64'; identifier=$script:AppIdentifier
        mainExecutableFile=$script:ExecutableName; installerFile=$versionedName; versionedInstallerFile=$versionedName
        publicInstallerFile=$script:PublicInstallerName; installerSizeBytes=4; sha256=$hash
        versionedInstallerSha256=$hash; publicInstallerSha256=$hash; gitCommit=$head
        dirtyWorktree=$false; characterSchemaVersion=1
    }
    Write-Utf8NoBom ([System.IO.Path]::Combine($release, 'release-manifest.json')) ($manifest | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom ([System.IO.Path]::Combine($release, 'SHA256SUMS.txt')) "$hash  $versionedName`r`n$hash  $script:PublicInstallerName`r`n"
    Write-Utf8NoBom ([System.IO.Path]::Combine($updaterRoot, 'latest.json')) (([ordered]@{ version=$historicalVersion } | ConvertTo-Json))
    Write-Utf8NoBom ([System.IO.Path]::Combine($historicalDirectory, 'updater-release-manifest.json')) (([ordered]@{ version=$historicalVersion } | ConvertTo-Json))

    $historicalOnly = Invoke-ReleaseVerification -ReleaseDirectory $release
    Add-Test 'Historical updater assets do not fail current unsigned release verification' ($historicalOnly.ExitCode -eq 0) "exit=$($historicalOnly.ExitCode)"
    Add-Test 'Historical-only verification reports updater NOT_CONFIGURED' ($historicalOnly.Output -match '"UpdaterStatus"\s*:\s*"NOT_CONFIGURED"') 'Expected version-scoped updater state.'
    Add-Test 'Historical-only verification keeps updater optional' ($historicalOnly.Output -match '"UpdaterRequired"\s*:\s*false') 'Expected UpdaterRequired=false.'
    Add-Test 'Historical-only verification has zero failed checks' ($historicalOnly.Output -match '"ChecksFailed"\s*:\s*0') 'Expected ChecksFailed=0.'

    $currentDirectory = [System.IO.Path]::Combine($updaterRoot, $version)
    [void][System.IO.Directory]::CreateDirectory($currentDirectory)
    Write-Utf8NoBom ([System.IO.Path]::Combine($currentDirectory, 'orphan.sig')) 'incomplete-current-candidate'
    $currentPartial = Invoke-ReleaseVerification -ReleaseDirectory $release
    Add-Test 'Current-version partial updater evidence fails release verification' ($currentPartial.ExitCode -eq 2) "exit=$($currentPartial.ExitCode)"
    Add-Test 'Current-version partial evidence is reported as MISCONFIGURED' ($currentPartial.Output -match '"UpdaterStatus"\s*:\s*"MISCONFIGURED"') 'Expected fail-closed updater state.'
} finally {
    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
}

$results | Format-Table -AutoSize
[pscustomobject]@{
    Name='Windows PowerShell 5.1 host'
    Passed=$PSVersionTable.PSVersion.Major -eq 5
    Details=$PSVersionTable.PSVersion.ToString()
} | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -gt 0 -or $PSVersionTable.PSVersion.Major -ne 5) { exit 1 }
exit 0
