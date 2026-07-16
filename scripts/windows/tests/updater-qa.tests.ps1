[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Add-Test([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-Test $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}
function Test-NoThrow([string]$Name, [scriptblock]$Action) {
    try { & $Action; Add-Test $Name $true 'No exception.' } catch { Add-Test $Name $false $_.Exception.Message }
}
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action; Add-Test $Name $false 'No exception was thrown.' }
    catch { Add-Test $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}
function Write-Utf8NoBom([string]$Path, [string]$Value) {
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-NativeFixtureCommand([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 120) {
    $toolingCommon = [System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'updater', 'common.ps1')
    return & {
        param($CommonPath, $NativeFilePath, $NativeArguments, $Timeout)
        . $CommonPath
        Invoke-UpdaterToolProcess -FilePath $NativeFilePath -ArgumentList $NativeArguments -TimeoutSeconds $Timeout
    } $toolingCommon $FilePath $ArgumentList $TimeoutSeconds
}

$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'desk-pet-updater-qa-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($root) | Out-Null
try {
    Test-Equal 'SemVer prerelease increments in order' -1 (Compare-DeskPetSemVer '0.2.0-beta.1' '0.2.0-beta.2')
    Test-Equal 'SemVer prerelease is lower than stable' -1 (Compare-DeskPetSemVer '0.2.0-beta.2' '0.2.0')
    Test-Equal 'SemVer next patch prerelease is higher than current stable' -1 (Compare-DeskPetSemVer '0.2.0' '0.2.1-beta.1')
    Test-Equal 'SemVer build metadata does not change precedence' 0 (Compare-DeskPetSemVer '0.2.0+one' '0.2.0+two')
    Test-Throws 'Same-version reinstall is not an upgrade' {
        Assert-DeskPetUpgradeIdentity '0.2.0' '0.2.0' $script:AppIdentifier $script:AppIdentifier 'ABC' 'ABC'
    } 'previous < current'
    Test-Throws 'Downgrade is not an upgrade' {
        Assert-DeskPetUpgradeIdentity '0.2.1' '0.2.0' $script:AppIdentifier $script:AppIdentifier 'ABC' 'ABC'
    } 'previous < current'
    Test-Throws 'Upgrade identifier must remain stable' {
        Assert-DeskPetUpgradeIdentity '0.2.0' '0.2.1' 'old.identifier' $script:AppIdentifier 'ABC' 'ABC'
    } 'identifier mismatch'
    Test-Throws 'Upgrade public key must remain stable' {
        Assert-DeskPetUpgradeIdentity '0.2.0' '0.2.1' $script:AppIdentifier $script:AppIdentifier 'ABC' 'DEF'
    } 'fingerprint mismatch'
    Test-NoThrow 'Valid beta A to B identity is accepted' {
        Assert-DeskPetUpgradeIdentity '0.2.0-beta.1' '0.2.1-beta.1' $script:AppIdentifier $script:AppIdentifier 'ABC' 'ABC'
    }

    $publicKeyWithoutNewline = [System.IO.Path]::Combine($root, 'updater-public-no-newline.key.pub')
    $publicKeyWithNewline = [System.IO.Path]::Combine($root, 'updater-public-with-newline.key.pub')
    $publicKeyText = [Convert]::ToBase64String([byte[]](1..48))
    Write-Utf8NoBom $publicKeyWithoutNewline $publicKeyText
    Write-Utf8NoBom $publicKeyWithNewline ($publicKeyText + "`r`n")
    $fingerprintWithoutNewline = Get-UpdaterPublicKeyFingerprint -PublicKeyPath $publicKeyWithoutNewline
    $fingerprintWithNewline = Get-UpdaterPublicKeyFingerprint -PublicKeyPath $publicKeyWithNewline
    Test-Equal 'Public-key fingerprint ignores a trailing newline' $fingerprintWithoutNewline $fingerprintWithNewline
    Test-Equal 'Public-key fingerprint hashes canonical trimmed UTF-8 text' (Get-DeskPetStringSha256 $publicKeyText) $fingerprintWithoutNewline

    $versionRoot = [System.IO.Path]::Combine($root, 'version')
    $tauriDirectory = [System.IO.Path]::Combine($versionRoot, 'src-tauri')
    $releaseDirectory = [System.IO.Path]::Combine($versionRoot, 'release')
    [System.IO.Directory]::CreateDirectory($tauriDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($releaseDirectory) | Out-Null
    $version = '0.2.0-beta.1'
    Write-Utf8NoBom ([System.IO.Path]::Combine($versionRoot, 'package.json')) (([ordered]@{ version=$version } | ConvertTo-Json))
    Write-Utf8NoBom ([System.IO.Path]::Combine($tauriDirectory, 'tauri.conf.json')) (([ordered]@{ productName=$script:ProductName; mainBinaryName=$script:MainBinaryName; version=$version; identifier=$script:AppIdentifier } | ConvertTo-Json))
    Write-Utf8NoBom ([System.IO.Path]::Combine($tauriDirectory, 'Cargo.toml')) "[package]`nname = `"fixture-app`"`nversion = `"$version`"`n"
    Write-Utf8NoBom ([System.IO.Path]::Combine($tauriDirectory, 'Cargo.lock')) "version = 4`n`n[[package]]`nname = `"fixture-app`"`nversion = `"$version`"`n"
    $installerName = "$script:ProductName`_$version`_x64-setup.exe"
    $installerPath = [System.IO.Path]::Combine($releaseDirectory, $installerName)
    [System.IO.File]::WriteAllBytes($installerPath, [byte[]](1,2,3))
    Write-Utf8NoBom ([System.IO.Path]::Combine($releaseDirectory, 'release-manifest.json')) (([ordered]@{ version=$version; versionedInstallerFile=$installerName } | ConvertTo-Json))
    $versionContext = Resolve-DeskPetVersionContext -RepositoryRoot $versionRoot -ReleaseDirectory $releaseDirectory -InstallerPath $installerPath -ExplicitExpectedVersion $version
    Test-Equal 'Tauri is the authoritative expected version' $version $versionContext.ExpectedVersion
    Test-NoThrow 'Package, Cargo and Cargo.lock matching Tauri are accepted' { Assert-DeskPetVersionContext $versionContext }
    $versionContext.PackageVersion = '0.2.0'
    Test-Throws 'Package version mismatch is rejected' { Assert-DeskPetVersionContext $versionContext } 'package=0\.2\.0'

    $unconfiguredRelease = [System.IO.Path]::Combine($root, 'unconfigured-release')
    [System.IO.Directory]::CreateDirectory($unconfiguredRelease) | Out-Null
    $unconfigured = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $unconfiguredRelease -ExpectedVersion '0.2.0-beta.1'
    Test-Equal 'No production updater evidence is NOT_CONFIGURED' 'NOT_CONFIGURED' $unconfigured.State

    $partialRelease = [System.IO.Path]::Combine($root, 'partial-release')
    $partialUpdater = [System.IO.Path]::Combine($partialRelease, 'updater')
    [System.IO.Directory]::CreateDirectory($partialUpdater) | Out-Null
    Write-Utf8NoBom ([System.IO.Path]::Combine($partialUpdater, 'latest.json')) '{}'
    $partial = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $partialRelease -ExpectedVersion '0.2.0-beta.1'
    Test-Equal 'Partial updater evidence is MISCONFIGURED, not disabled' 'MISCONFIGURED' $partial.State

    $readyRelease = [System.IO.Path]::Combine($root, 'ready-release')
    $versionUpdaterDirectory = [System.IO.Path]::Combine($readyRelease, 'updater', $version)
    [System.IO.Directory]::CreateDirectory($versionUpdaterDirectory) | Out-Null
    $artifactName = "$script:ProductName`_$version`_x64-setup.exe"
    $signatureName = "$artifactName.sig"
    $artifactPath = [System.IO.Path]::Combine($versionUpdaterDirectory, $artifactName)
    $signaturePath = [System.IO.Path]::Combine($versionUpdaterDirectory, $signatureName)
    [System.IO.File]::WriteAllBytes($artifactPath, [byte[]](10,20,30,40))
    $signatureText = [Convert]::ToBase64String([byte[]](1..48))
    Write-Utf8NoBom $signaturePath $signatureText
    $artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    $downloadUrl = "https://updates.example.invalid/$version/$artifactName"
    $latest = [ordered]@{
        version=$version
        platforms=[ordered]@{ 'windows-x86_64'=[ordered]@{ url=$downloadUrl; signature=$signatureText; size=4 } }
    }
    $updaterRoot = [System.IO.Path]::Combine($readyRelease, 'updater')
    $latestPath = [System.IO.Path]::Combine($updaterRoot, 'latest.json')
    Write-Utf8NoBom $latestPath ($latest | ConvertTo-Json -Depth 6)
    $headCommit = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
    Write-Utf8NoBom ([System.IO.Path]::Combine($readyRelease, 'release-manifest.json')) (([ordered]@{ version=$version; gitCommit=$headCommit } | ConvertTo-Json))
    $manifest = [ordered]@{
        schemaVersion=1; version=$version; currentVersion='0.1.0'; identifier=$script:AppIdentifier; publicKeyFingerprint=('A' * 64 -join '')
        endpoint='https://updates.example.invalid/latest.json'; installMode='passive'; artifactFile=$artifactName; signatureFile=$signatureName; artifactSha256=$artifactHash
        signatureSha256=(Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash; latestJsonSha256=(Get-FileHash -LiteralPath $latestPath -Algorithm SHA256).Hash
        downloadUrl=$downloadUrl; gitCommit=$headCommit; dirtyWorktree=$false
    }
    Write-Utf8NoBom ([System.IO.Path]::Combine($versionUpdaterDirectory, 'updater-release-manifest.json')) ($manifest | ConvertTo-Json -Depth 5)
    $ready = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $readyRelease -ExpectedVersion $version
    Test-Equal 'Complete signed HTTPS updater evidence is READY' 'READY' $ready.State
    Test-Equal 'Ready updater has no failed checks' 0 @($ready.Checks | Where-Object { -not $_.Passed }).Count

    $latest.platforms.'windows-x86_64'.url = "https://updates.example.invalid/$version/alias-$artifactName"
    Write-Utf8NoBom $latestPath ($latest | ConvertTo-Json -Depth 6)
    $aliasedUrl = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $readyRelease -ExpectedVersion $version
    Test-Equal 'Updater URL filename alias is rejected' 'MISCONFIGURED' $aliasedUrl.State
    $latest.platforms.'windows-x86_64'.url = $downloadUrl
    Write-Utf8NoBom $latestPath ($latest | ConvertTo-Json -Depth 6)

    $latest.platforms.'windows-x86_64'.signature = $signatureText.Substring(0, 1).ToLowerInvariant() + $signatureText.Substring(1)
    Write-Utf8NoBom $latestPath ($latest | ConvertTo-Json -Depth 6)
    $caseMutatedSignature = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $readyRelease -ExpectedVersion $version
    $detachedSignatureCheck = @($caseMutatedSignature.Checks | Where-Object Name -eq 'Updater detached signature')[0]
    Test-Equal 'latest.json signature comparison is case-sensitive' $false ([bool]$detachedSignatureCheck.Passed)
    $latest.platforms.'windows-x86_64'.signature = $signatureText
    Write-Utf8NoBom $latestPath ($latest | ConvertTo-Json -Depth 6)

    $manifest.endpoint = 'http://updates.example.invalid/latest.json'
    Write-Utf8NoBom ([System.IO.Path]::Combine($versionUpdaterDirectory, 'updater-release-manifest.json')) ($manifest | ConvertTo-Json -Depth 5)
    $httpUpdater = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $readyRelease -ExpectedVersion $version
    Test-Equal 'HTTP updater endpoint is rejected' 'MISCONFIGURED' $httpUpdater.State
    $manifest.endpoint = 'https://updates.example.invalid/latest.json'
    Write-Utf8NoBom ([System.IO.Path]::Combine($versionUpdaterDirectory, 'updater-release-manifest.json')) ($manifest | ConvertTo-Json -Depth 5)
    [System.IO.File]::Delete($signaturePath)
    $missingSignature = Get-DeskPetUpdaterReadiness -RepositoryRoot $script:RepositoryRoot -ReleaseDirectory $readyRelease -ExpectedVersion $version
    Test-Equal 'Missing detached signature is rejected' 'MISCONFIGURED' $missingSignature.State

    $cryptoRoot = [System.IO.Path]::Combine($root, 'cryptographic-gate')
    [System.IO.Directory]::CreateDirectory($cryptoRoot) | Out-Null
    $tauriCli = [System.IO.Path]::Combine($script:RepositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
    $temporarySigningPassword = [Guid]::NewGuid().ToString('N')
    $keyOne = [System.IO.Path]::Combine($cryptoRoot, 'one.key')
    $keyTwo = [System.IO.Path]::Combine($cryptoRoot, 'two.key')
    Test-Equal 'Temporary QA key A is generated' 0 (Invoke-NativeFixtureCommand $tauriCli @('signer','generate','--write-keys',$keyOne,'--password',$temporarySigningPassword,'--ci'))
    Test-Equal 'Temporary QA key B is generated' 0 (Invoke-NativeFixtureCommand $tauriCli @('signer','generate','--write-keys',$keyTwo,'--password',$temporarySigningPassword,'--ci'))
    $signedArtifact = [System.IO.Path]::Combine($cryptoRoot, 'qa-artifact-0.2.0-beta.1.bin')
    [System.IO.File]::WriteAllBytes($signedArtifact, [byte[]](3,1,4,1,5,9,2,6))
    $previousSigningPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $temporarySigningPassword, 'Process')
        Test-Equal 'Temporary QA artifact is signed' 0 (Invoke-NativeFixtureCommand $tauriCli @('signer','sign','--private-key-path',$keyOne,$signedArtifact))
    } finally {
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousSigningPassword, 'Process')
    }
    $signedSignature = $signedArtifact + '.sig'
    Test-Equal 'QA Gate accepts the correct artifact, signature and public key' $true `
        (Test-DeskPetUpdaterArtifactSignature -ArtifactPath $signedArtifact -SignaturePath $signedSignature -PublicKeyPath ($keyOne + '.pub'))
    Test-Equal 'QA Gate rejects the wrong public key cryptographically' $false `
        (Test-DeskPetUpdaterArtifactSignature -ArtifactPath $signedArtifact -SignaturePath $signedSignature -PublicKeyPath ($keyTwo + '.pub'))
    $mutatedArtifact = [System.IO.Path]::Combine($cryptoRoot, 'qa-artifact-mutated-0.2.0-beta.1.bin')
    [System.IO.File]::WriteAllBytes($mutatedArtifact, [byte[]](3,1,4,1,5,9,2,7))
    [System.IO.File]::Copy($signedSignature, $mutatedArtifact + '.sig')
    Test-Equal 'QA Gate rejects a mutated artifact cryptographically' $false `
        (Test-DeskPetUpdaterArtifactSignature -ArtifactPath $mutatedArtifact -SignaturePath ($mutatedArtifact + '.sig') -PublicKeyPath ($keyOne + '.pub'))
} finally {
    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
