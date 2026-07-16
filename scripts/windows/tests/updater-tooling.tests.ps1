[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$updaterTools = [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'updater')
. ([System.IO.Path]::Combine($updaterTools, 'common.ps1'))

$results = @()
function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-TestResult $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}
function Test-True([string]$Name, [bool]$Actual, [string]$Details = '') {
    Add-TestResult $Name $Actual $Details
}
function Test-NoThrow([string]$Name, [scriptblock]$Action) {
    try { & $Action | Out-Null; Add-TestResult $Name $true 'No exception.' } catch { Add-TestResult $Name $false $_.Exception.Message }
}
function Test-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null; Add-TestResult $Name $false 'No exception was thrown.' } catch { Add-TestResult $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}
function Invoke-NativeFixtureCommand([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 60) {
    return Invoke-UpdaterToolProcess -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
}
function Invoke-TemporaryTauriSigningCommand([string]$TauriCli, [string[]]$ArgumentList, [string]$Password) {
    $previousPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $Password, 'Process')
        return Invoke-NativeFixtureCommand -FilePath $TauriCli -ArgumentList $ArgumentList -TimeoutSeconds 60
    } finally {
        [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousPassword, 'Process')
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$temporaryRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), (-join @([char]0x4E03,[char]0x9171,' updater tooling ',[Guid]::NewGuid().ToString('N'))))
[void][System.IO.Directory]::CreateDirectory($temporaryRoot)
try {
    Test-Equal 'Stable SemVer sorts after prerelease' 1 (Compare-SemVer -Left '0.2.0' -Right '0.2.0-beta.9')
    Test-Equal 'Numeric prerelease identifiers use numeric ordering' -1 (Compare-SemVer -Left '0.2.0-beta.9' -Right '0.2.0-beta.10')
    Test-Equal 'Build metadata does not affect precedence' 0 (Compare-SemVer -Left '0.2.0+build.1' -Right '0.2.0+build.2')
    Test-Throws 'SemVer rejects leading zeroes' { Get-SemVerParts -Version '0.2.01' } 'Invalid semantic version'
    Test-Throws 'Candidate version must be strictly newer' { Assert-UpdaterVersionIncrease -CurrentVersion '0.2.0' -Version '0.2.0' } 'must be higher'
    Test-Equal 'Direct process helper avoids Windows PowerShell Path/PATH collisions' 0 `
        (Invoke-UpdaterToolProcess -FilePath $env:ComSpec -ArgumentList @('/d','/c','exit','0') -TimeoutSeconds 10)

    $tauriCli = [System.IO.Path]::Combine($repositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
    $temporarySigningPassword = [Guid]::NewGuid().ToString('N')
    $temporaryKeyOne = [System.IO.Path]::Combine($temporaryRoot, 'temporary-one.key')
    $temporaryKeyTwo = [System.IO.Path]::Combine($temporaryRoot, 'temporary-two.key')
    $generateOne = Invoke-NativeFixtureCommand -FilePath $tauriCli -ArgumentList @('signer','generate','--write-keys',$temporaryKeyOne,'--password',$temporarySigningPassword,'--ci')
    $generateTwo = Invoke-NativeFixtureCommand -FilePath $tauriCli -ArgumentList @('signer','generate','--write-keys',$temporaryKeyTwo,'--password',$temporarySigningPassword,'--ci')
    Test-Equal 'Temporary integration key A is generated only under the test directory' 0 $generateOne
    Test-Equal 'Temporary integration key B is generated only under the test directory' 0 $generateTwo
    $artifactPath = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x4E03,[char]0x9171,' desk pet 0.2.0-beta.1.exe')))
    $signaturePath = $artifactPath + '.sig'
    $publicKeyPath = $temporaryKeyOne + '.pub'
    [System.IO.File]::WriteAllBytes($artifactPath, [byte[]](1,2,3,4,5,6,7,8))
    $artifactSignExit = Invoke-TemporaryTauriSigningCommand -TauriCli $tauriCli -ArgumentList @('signer','sign','--private-key-path',$temporaryKeyOne,$artifactPath) -Password $temporarySigningPassword
    Test-Equal 'Temporary integration key signs the versioned artifact' 0 $artifactSignExit
    $signature = Get-UpdaterSignatureText -SignaturePath $signaturePath
    $artifactDownloadUrl = 'https://updates.qijiang-desktop-pet.com/files/' + [Uri]::EscapeDataString([System.IO.Path]::GetFileName($artifactPath))
    $latestPath = [System.IO.Path]::Combine($temporaryRoot, 'latest.json')
    $createScript = [System.IO.Path]::Combine($updaterTools, 'create-latest-json.ps1')
    & $createScript -Version '0.2.0-beta.1' -CurrentVersion '0.1.0' -ArtifactPath $artifactPath `
        -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath -DownloadUrl $artifactDownloadUrl `
        -OutputPath $latestPath -Notes (-join @([char]0x516C,[char]0x5F00,[char]0x6D4B,[char]0x8BD5)) | Out-Null
    Test-True 'latest.json is created in a Unicode and space-containing path' ([System.IO.File]::Exists($latestPath)) $latestPath
    $latestBytes = [System.IO.File]::ReadAllBytes($latestPath)
    $hasBom = $latestBytes.Length -ge 3 -and $latestBytes[0] -eq 0xEF -and $latestBytes[1] -eq 0xBB -and $latestBytes[2] -eq 0xBF
    Test-Equal 'latest.json uses UTF-8 without BOM' $false $hasBom
    $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'latest.json records the candidate version' '0.2.0-beta.1' ([string]$latest.version)
    Test-Equal 'latest.json embeds actual signature file text' $signature ([string]$latest.platforms.'windows-x86_64'.signature)
    Test-Equal 'latest.json records the exact artifact size' (Get-Item -LiteralPath $artifactPath).Length ([long]$latest.platforms.'windows-x86_64'.size)
    Test-Equal 'latest.json preserves Unicode release notes' (-join @([char]0x516C,[char]0x5F00,[char]0x6D4B,[char]0x8BD5)) ([string]$latest.notes)
    Test-NoThrow 'latest.json validates under the previous version' {
        & ([System.IO.Path]::Combine($updaterTools, 'validate-latest-json.ps1')) -LatestJsonPath $latestPath -CurrentVersion '0.1.0' -ExpectedVersion '0.2.0-beta.1' `
            -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $publicKeyPath
    }
    Test-Throws 'latest.json creation refuses overwrite' {
        & $createScript -Version '0.2.0-beta.1' -CurrentVersion '0.1.0' -ArtifactPath $artifactPath -SignaturePath $signaturePath `
            -PublicKeyPath $publicKeyPath -DownloadUrl 'https://updates.qijiang-desktop-pet.com/files/qijiang.exe' -OutputPath $latestPath
    } 'Refusing to overwrite'
    Test-Throws 'HTTP updater downloads are rejected' {
        New-UpdaterLatestDocument -Version '0.2.0' -CurrentVersion '0.1.0' -DownloadUrl 'http://updates.qijiang-desktop-pet.com/file.exe' `
            -Signature $signature -Platform 'windows-x86_64' -PublishedAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -ArtifactSizeBytes 1
    } 'must use HTTPS'
    Test-Throws 'Token-bearing updater URLs are rejected' {
        Assert-UpdaterHttpsUrl -Url 'https://updates.qijiang-desktop-pet.com/file.exe?token=unsafe'
    } 'must not contain'
    Test-Throws 'Reserved example updater hosts are rejected for production tooling' {
        Assert-UpdaterHttpsUrl -Url 'https://updates.example.com/file.exe'
    } 'reserved or local-only'
    Test-Throws 'Loopback updater endpoints are rejected for production tooling' {
        Assert-UpdaterHttpsUrl -Url 'https://127.0.0.1/latest.json'
    } 'public DNS hostname'
    Test-Throws 'Public installer aliases cannot be used as updater artifacts' {
        Assert-UpdaterArtifactBinding -ArtifactPath ([System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0,'.exe')))) `
            -Version '0.2.0-beta.1' -DownloadUrl 'https://updates.qijiang-desktop-pet.com/files/public-installer.exe'
    } 'must contain the exact version'
    Test-Throws 'Updater URL filename must match the versioned artifact' {
        Assert-UpdaterArtifactBinding -ArtifactPath $artifactPath -Version '0.2.0-beta.1' `
            -DownloadUrl 'https://updates.qijiang-desktop-pet.com/files/different-0.2.0-beta.1.exe'
    } 'must exactly match'
    $emptySignature = [System.IO.Path]::Combine($temporaryRoot, 'empty.sig')
    [System.IO.File]::WriteAllText($emptySignature, '', $utf8NoBom)
    Test-Throws 'Empty signature files are rejected' { Get-UpdaterSignatureText -SignaturePath $emptySignature } 'empty'
    $bomSignature = [System.IO.Path]::Combine($temporaryRoot, 'bom.sig')
    [System.IO.File]::WriteAllBytes($bomSignature, [byte[]](0xEF,0xBB,0xBF,65,65,65,65))
    Test-Throws 'BOM signature files are rejected' { Get-UpdaterSignatureText -SignaturePath $bomSignature } 'BOM'
    Test-Throws 'Metadata rejects local user paths' { Assert-NoUpdaterSensitiveMetadata -Text '{"path":"C:\\Users\\local-user\\key"}' } 'local path or secret'

    $releaseRoot = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x53D1,[char]0x5E03,' output')))
    $prepareScript = [System.IO.Path]::Combine($updaterTools, 'prepare-updater-release.ps1')
    $prepareArguments = @{
        Version='0.2.0-beta.1'; CurrentVersion='0.1.0'; ArtifactPath=$artifactPath; SignaturePath=$signaturePath
        PublicKeyPath=$publicKeyPath; DownloadUrl=$artifactDownloadUrl
        Endpoint='https://updates.qijiang-desktop-pet.com/qijiang/latest.json'; Identifier='dev.deskpet.framework'
        ReleaseDirectory=$releaseRoot; Notes=(-join @([char]0x516C,[char]0x5F00,[char]0x6D4B,[char]0x8BD5))
    }
    $previewReleaseRoot = [System.IO.Path]::Combine($temporaryRoot, 'prepare preview only')
    $previewArguments = $prepareArguments.Clone()
    $previewArguments.ReleaseDirectory = $previewReleaseRoot
    $preparePlan = & $prepareScript @previewArguments -WhatIf
    Test-Equal 'Updater release preparation supports WhatIf preview' 'PreviewOnly' ([string]$preparePlan.Mode)
    Test-Equal 'Updater release WhatIf creates no output directory' $false ([System.IO.Directory]::Exists($previewReleaseRoot))
    & $prepareScript @prepareArguments | Out-Null
    $versionDirectory = [System.IO.Path]::Combine($releaseRoot, 'updater', '0.2.0-beta.1')
    $manifestPath = [System.IO.Path]::Combine($versionDirectory, 'updater-release-manifest.json')
    $topLatest = [System.IO.Path]::Combine($releaseRoot, 'updater', 'latest.json')
    Test-True 'Versioned updater release directory is prepared' ([System.IO.Directory]::Exists($versionDirectory)) $versionDirectory
    Test-True 'Top-level release/updater/latest.json is prepared' ([System.IO.File]::Exists($topLatest)) $topLatest
    $manifestText = Get-FileTextWithoutBom -LiteralPath $manifestPath
    $manifest = $manifestText | ConvertFrom-Json
    Test-Equal 'Updater manifest binds the stable identifier' 'dev.deskpet.framework' ([string]$manifest.identifier)
    Test-Equal 'Updater manifest preserves the Unicode application name' (-join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0)) ([string]$manifest.applicationName)
    Test-Equal 'Updater manifest binds the HTTPS endpoint' 'https://updates.qijiang-desktop-pet.com/qijiang/latest.json' ([string]$manifest.endpoint)
    Test-Equal 'Updater manifest pins passive Windows installation' 'passive' ([string]$manifest.installMode)
    Test-Equal 'Updater manifest fingerprints canonical trimmed public-key text' (Get-UpdaterPublicKeyFingerprint -LiteralPath $publicKeyPath) ([string]$manifest.publicKeyFingerprint)
    Test-Equal 'Updater manifest contains only an artifact filename' ([System.IO.Path]::GetFileName($artifactPath)) ([string]$manifest.artifactFile)
    Test-Equal 'Updater manifest and latest.json use the same artifact size' ([long]$latest.platforms.'windows-x86_64'.size) ([long]$manifest.artifactSizeBytes)
    Test-Equal 'Updater manifest records completed cryptographic verification' $true ([bool]$manifest.cryptographicSignatureVerified)
    Test-NoThrow 'Updater manifest contains no sensitive metadata' { Assert-NoUpdaterSensitiveMetadata -Text $manifestText }
    $expectedGitState = Get-UpdaterGitState -RepositoryRoot $repositoryRoot
    Test-Equal 'Updater manifest records the actual Git worktree state' $expectedGitState.DirtyWorktree ([bool]$manifest.dirtyWorktree)
    Test-Equal 'Updater manifest records the current Git commit' $expectedGitState.Commit ([string]$manifest.gitCommit)
    Test-Throws 'Existing updater version directory is never overwritten' { & $prepareScript @prepareArguments } 'Refusing to overwrite'

    $artifactB = [System.IO.Path]::Combine($temporaryRoot, 'qijiang-0.2.1-beta.1.exe')
    $signatureB = $artifactB + '.sig'
    [System.IO.File]::WriteAllBytes($artifactB, [byte[]](8,7,6,5,4,3,2,1))
    $artifactBSignExit = Invoke-TemporaryTauriSigningCommand -TauriCli $tauriCli -ArgumentList @('signer','sign','--private-key-path',$temporaryKeyOne,$artifactB) -Password $temporarySigningPassword
    Test-Equal 'Temporary integration key signs upgrade artifact B' 0 $artifactBSignExit
    $prepareB = @{
        Version='0.2.1-beta.1'; CurrentVersion='0.2.0-beta.1'; ArtifactPath=$artifactB; SignaturePath=$signatureB
        PublicKeyPath=$publicKeyPath; DownloadUrl='https://updates.qijiang-desktop-pet.com/files/qijiang-0.2.1-beta.1.exe'
        Endpoint='https://updates.qijiang-desktop-pet.com/qijiang/latest.json'; Identifier='dev.deskpet.framework'
        ReleaseDirectory=$releaseRoot
    }
    $differentPublicKey = $temporaryKeyTwo + '.pub'
    $mismatchedKeyArguments = $prepareB.Clone()
    $mismatchedKeyArguments.PublicKeyPath = $differentPublicKey
    Test-Throws 'A/B preparation rejects public-key fingerprint changes' { & $prepareScript @mismatchedKeyArguments } 'public-key fingerprint continuity'
    Test-Equal 'Rejected key transition creates no B version directory' $false ([System.IO.Directory]::Exists([System.IO.Path]::Combine($releaseRoot, 'updater', '0.2.1-beta.1')))
    & $prepareScript @prepareB | Out-Null
    $advancedLatest = Get-Content -LiteralPath $topLatest -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'A/B preparation advances top-level latest.json' '0.2.1-beta.1' ([string]$advancedLatest.version)
    $manifestB = Get-Content -LiteralPath ([System.IO.Path]::Combine($releaseRoot, 'updater', '0.2.1-beta.1', 'updater-release-manifest.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'A/B manifests keep the same identifier' ([string]$manifest.identifier) ([string]$manifestB.identifier)
    Test-Equal 'A/B manifests keep the same public-key fingerprint' ([string]$manifest.publicKeyFingerprint) ([string]$manifestB.publicKeyFingerprint)

    $publicKeyWithNewline = [System.IO.Path]::Combine($temporaryRoot, 'public-with-newline.key.pub')
    [System.IO.File]::WriteAllText($publicKeyWithNewline, (Get-UpdaterPublicKeyText -LiteralPath $publicKeyPath) + "`r`n", $utf8NoBom)
    Test-Equal 'Public-key fingerprint ignores trailing line endings' (Get-UpdaterPublicKeyFingerprint -LiteralPath $publicKeyPath) (Get-UpdaterPublicKeyFingerprint -LiteralPath $publicKeyWithNewline)

    $privateKeyPath = [System.IO.Path]::Combine($temporaryRoot, 'formal-updater.key')
    [System.IO.File]::WriteAllText($privateKeyPath, "untrusted comment: rsign encrypted secret key`nfixture-private-key-material", $utf8NoBom)
    $keyCheck = Test-UpdaterKeyFiles -PrivateKeyPath $privateKeyPath -PublicKeyPath $publicKeyPath -RepositoryRoot $repositoryRoot
    Test-Equal 'External key pair structure can be verified without printing key content' $true ([bool]$keyCheck.Valid)
    Test-Throws 'Private key paths inside the repository are rejected' {
        Assert-UpdaterPrivateKeyPath -KeyPath ([System.IO.Path]::Combine($repositoryRoot, 'unsafe.key')) -RepositoryRoot $repositoryRoot
    } 'outside the repository'

    $previewKeyPath = [System.IO.Path]::Combine($temporaryRoot, 'preview-only.key')
    $keyPlan = & ([System.IO.Path]::Combine($updaterTools, 'initialize-updater-key.ps1')) -KeyPath $previewKeyPath
    Test-Equal 'Key initialization defaults to preview mode' 'PreviewOnly' ([string]$keyPlan.Mode)
    Test-Equal 'Key initialization preview creates no private key' $false ([System.IO.File]::Exists($previewKeyPath))
    Test-Equal 'Key initialization preview creates no public key' $false ([System.IO.File]::Exists($previewKeyPath + '.pub'))
    $keyWhatIfPlan = & ([System.IO.Path]::Combine($updaterTools, 'initialize-updater-key.ps1')) -KeyPath $previewKeyPath -Generate -WhatIf
    Test-Equal 'Explicit key generation still honors WhatIf' 'PreviewOnly' ([string]$keyWhatIfPlan.Mode)
    Test-Equal 'Key generation WhatIf creates no private key' $false ([System.IO.File]::Exists($previewKeyPath))

    $previousKeyEnvironment = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process')
    $previousPasswordEnvironment = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
    $previousRuntimeEndpoint = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', 'Process')
    $previousRuntimePublicKey = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', 'Process')
    $previousRuntimeChannel = [Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', 'Process')
    $buildPlan = & ([System.IO.Path]::Combine($updaterTools, 'build-signed-update.ps1')) -Version '0.1.0' `
        -EndpointBaseUrl 'https://updates.qijiang-desktop-pet.com/qijiang/' -PrivateKeyPath $previewKeyPath `
        -OutputDirectory ([System.IO.Path]::Combine($temporaryRoot, 'signed build preview')) -Execute -WhatIf
    Test-Equal 'Signed build defaults to preview mode' 'PreviewOnly' ([string]$buildPlan.Mode)
    Test-Equal 'Signed build preview preserves private-key environment' $previousKeyEnvironment ([Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process'))
    Test-Equal 'Signed build preview preserves password environment' $previousPasswordEnvironment ([Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process'))
    Test-Equal 'Signed build preview preserves runtime endpoint environment' $previousRuntimeEndpoint ([Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', 'Process'))
    Test-Equal 'Signed build preview preserves runtime public-key environment' $previousRuntimePublicKey ([Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', 'Process'))
    Test-Equal 'Signed build preview preserves runtime channel environment' $previousRuntimeChannel ([Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', 'Process'))

    $secretFixture = [System.IO.Path]::Combine($temporaryRoot, 'diagnostic.txt')
    $secretValue = -join @('not','-for','-output')
    $secretLine = (-join @('updater_', 'password', '=', $secretValue))
    [System.IO.File]::WriteAllText($secretFixture, $secretLine, $utf8NoBom)
    $secretFindings = @(Find-UpdaterSecretIndicators -LiteralPath $secretFixture)
    Test-Equal 'Secret scanner detects a secret-like assignment' 1 $secretFindings.Count
    $serializedFinding = $secretFindings | ConvertTo-Json -Compress
    Test-Equal 'Secret scanner result never includes the secret value' $false ([bool]($serializedFinding -match [regex]::Escape($secretValue)))

    $cryptoRoot = [System.IO.Path]::Combine($temporaryRoot, 'temporary cryptographic verification')
    [void][System.IO.Directory]::CreateDirectory($cryptoRoot)
    $signedPayload = [System.IO.Path]::Combine($cryptoRoot, 'signed-payload-0.2.2-beta.1.bin')
    [System.IO.File]::WriteAllBytes($signedPayload, [byte[]](9,4,2,7,1,8,3,6,5))
    $signExit = Invoke-TemporaryTauriSigningCommand -TauriCli $tauriCli -ArgumentList @('signer','sign','--private-key-path',$temporaryKeyOne,$signedPayload) -Password $temporarySigningPassword
    $actualSignaturePath = $signedPayload + '.sig'
    Test-Equal 'Tauri CLI creates a temporary updater signature' 0 $signExit
    Test-True 'Temporary updater signature file exists' ([System.IO.File]::Exists($actualSignaturePath)) $actualSignaturePath
    $actualSignature = Get-UpdaterSignatureText -SignaturePath $actualSignaturePath
    Test-Equal 'Correct temporary key verifies the signed updater payload' $true (Test-UpdaterArtifactSignature -ArtifactPath $signedPayload -SignaturePath $actualSignaturePath -PublicKeyPath ($temporaryKeyOne + '.pub'))
    Test-Equal 'Wrong temporary public key is rejected' $false (Test-UpdaterArtifactSignature -ArtifactPath $signedPayload -SignaturePath $actualSignaturePath -PublicKeyPath ($temporaryKeyTwo + '.pub'))
    $mutatedPayload = [System.IO.Path]::Combine($cryptoRoot, 'mutated-payload.bin')
    [System.IO.File]::WriteAllBytes($mutatedPayload, [byte[]](9,4,2,7,1,8,3,6,4))
    $mutatedPayloadSignature = $mutatedPayload + '.sig'
    [System.IO.File]::Copy($actualSignaturePath, $mutatedPayloadSignature)
    Test-Equal 'Mutated updater payload is rejected' $false (Test-UpdaterArtifactSignature -ArtifactPath $mutatedPayload -SignaturePath $mutatedPayloadSignature -PublicKeyPath ($temporaryKeyOne + '.pub'))
    $mutatedSignatureCharacters = $actualSignature.ToCharArray()
    $mutationIndex = [Math]::Floor($mutatedSignatureCharacters.Length / 2)
    $mutatedSignatureCharacters[$mutationIndex] = $(if ($mutatedSignatureCharacters[$mutationIndex] -eq 'A') { 'B' } else { 'A' })
    $mutatedSignaturePath = [System.IO.Path]::Combine($cryptoRoot, 'signed-payload-0.2.2-beta.1-mutated.bin.sig')
    $mutatedSignatureArtifact = $mutatedSignaturePath.Substring(0, $mutatedSignaturePath.Length - 4)
    [System.IO.File]::Copy($signedPayload, $mutatedSignatureArtifact)
    [System.IO.File]::WriteAllText($mutatedSignaturePath, (-join $mutatedSignatureCharacters), $utf8NoBom)
    Test-Equal 'Mutated updater signature is rejected' $false (Test-UpdaterArtifactSignature -ArtifactPath $mutatedSignatureArtifact -SignaturePath $mutatedSignaturePath -PublicKeyPath ($temporaryKeyOne + '.pub'))
    $cryptographicLatestPath = [System.IO.Path]::Combine($cryptoRoot, 'latest.json')
    & $createScript -Version '0.2.2-beta.1' -CurrentVersion '0.2.1-beta.1' -ArtifactPath $signedPayload `
        -SignaturePath $actualSignaturePath -PublicKeyPath ($temporaryKeyOne + '.pub') -DownloadUrl 'https://updates.qijiang-desktop-pet.com/files/signed-payload-0.2.2-beta.1.bin' `
        -OutputPath $cryptographicLatestPath | Out-Null
    $cryptographicLatest = Get-Content -LiteralPath $cryptographicLatestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'latest.json preserves the cryptographically verified signature text' $actualSignature ([string]$cryptographicLatest.platforms.'windows-x86_64'.signature)
    Test-NoThrow 'Signature extracted from latest.json validates cryptographically with local context' {
        & ([System.IO.Path]::Combine($updaterTools, 'validate-latest-json.ps1')) -LatestJsonPath $cryptographicLatestPath `
            -CurrentVersion '0.2.1-beta.1' -ExpectedVersion '0.2.2-beta.1' -ArtifactPath $signedPayload `
            -SignaturePath $actualSignaturePath -PublicKeyPath ($temporaryKeyOne + '.pub')
    }

    $repositoryPreviewPath = [System.IO.Path]::Combine($repositoryRoot, 'release', 'preview.json')
    Test-Equal 'Repository paths are redacted to a stable token' '%REPOSITORY%\release\preview.json' (ConvertTo-UpdaterRedactedPath $repositoryPreviewPath)
    $externalPreviewPath = [System.IO.Path]::Combine([System.IO.Path]::GetPathRoot($repositoryRoot), 'secure-updater-location', 'formal.key')
    Test-Equal 'Arbitrary external paths reveal only the basename' '<external>\formal.key' (ConvertTo-UpdaterRedactedPath $externalPreviewPath)

    $exampleConfigPath = [System.IO.Path]::Combine($repositoryRoot, 'config', 'updater.example.json')
    $exampleConfig = Get-Content -LiteralPath $exampleConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Equal 'Updater example remains disabled' $false ([bool]$exampleConfig.configured)
    Test-True 'Updater example documents an HTTPS endpoint' ([string]$exampleConfig.endpoint -match '^https://') ([string]$exampleConfig.endpoint)
    $gitignore = Get-Content -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, '.gitignore')) -Raw
    Test-True 'Git ignores updater private keys' ([bool]($gitignore -match '(?m)^\*\.key$')) '*.key'
    Test-True 'Git ignores generated updater public-key sidecars' ([bool]($gitignore -match '(?m)^\*\.key\.pub$')) '*.key.pub'
    Test-True 'Git ignores PEM signing material' ([bool]($gitignore -match '(?m)^\*\.pem$')) '*.pem'
} finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) { [System.IO.Directory]::Delete($temporaryRoot, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
