[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$updaterTools = [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'updater')
. ([System.IO.Path]::Combine($updaterTools, 'common.ps1'))
$configuredApplicationVersion = [string]((Get-Content -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, 'src-tauri', 'tauri.conf.json')) -Raw -Encoding UTF8 | ConvertFrom-Json).version)

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
$previousUpdaterTestMode = [Environment]::GetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', 'Process')
[Environment]::SetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', '1', 'Process')
try {
    $qaSuiteText = [System.IO.File]::ReadAllText(
        [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'windows', 'run-qa-suite.ps1'),
        [System.Text.Encoding]::UTF8
    )
    Test-True 'QA suite discovers every Windows PowerShell regression file' `
        ($qaSuiteText -match "Get-ChildItem\s+-LiteralPath\s+''\.\\scripts\\windows\\tests''\s+-Filter\s+''\*\.tests\.ps1''") `
        'The aggregate suite must not omit newly added regression files.'
    Test-True 'QA suite isolates each regression file in a fresh PowerShell process' `
        ($qaSuiteText -match '& powershell\.exe\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File\s+\$test\.FullName') `
        'A fresh process prevents an expected child-command failure from leaving a stale LASTEXITCODE.'

    Test-Equal 'Stable SemVer sorts after prerelease' 1 (Compare-SemVer -Left '0.2.0' -Right '0.2.0-beta.9')
    Test-Equal 'Numeric prerelease identifiers use numeric ordering' -1 (Compare-SemVer -Left '0.2.0-beta.9' -Right '0.2.0-beta.10')
    Test-Equal 'Build metadata does not affect precedence' 0 (Compare-SemVer -Left '0.2.0+build.1' -Right '0.2.0+build.2')
    Test-Throws 'SemVer rejects leading zeroes' { Get-SemVerParts -Version '0.2.01' } 'Invalid semantic version'
    Test-Throws 'Candidate version must be strictly newer' { Assert-UpdaterVersionIncrease -CurrentVersion '0.2.0' -Version '0.2.0' } 'must be higher'
    Test-Equal 'Direct process helper avoids Windows PowerShell Path/PATH collisions' 0 `
        (Invoke-UpdaterToolProcess -FilePath $env:ComSpec -ArgumentList @('/d','/c','exit','0') -TimeoutSeconds 10)

    $tauriCli = [System.IO.Path]::Combine($repositoryRoot, 'node_modules', '.bin', 'tauri.cmd')
    $batchFixture = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x4E03,[char]0x9171,' safe tool.cmd')))
    [System.IO.File]::WriteAllText($batchFixture, "@exit /b 0`r`n", [System.Text.Encoding]::ASCII)
    Test-Equal 'Batch helper supports Unicode, spaces, and ordinary path arguments' 0 `
        (Invoke-UpdaterToolProcess -FilePath $batchFixture -ArgumentList @((-join @([char]0x4E2D,[char]0x6587,' safe path'))))
    foreach ($metacharacter in @('&','|','<','>','^','(',')','%','!')) {
        Test-Throws "Batch helper rejects cmd metacharacter $metacharacter" {
            Invoke-UpdaterToolProcess -FilePath $batchFixture -ArgumentList @('unsafe' + $metacharacter + 'argument')
        } 'must not contain cmd.exe metacharacters'
    }
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
    $snapshotSourcePublicKey = [System.IO.Path]::Combine($temporaryRoot, 'snapshot-source.key.pub')
    $snapshotPublicKey = [System.IO.Path]::Combine($temporaryRoot, 'snapshot.key.pub')
    [System.IO.File]::Copy($publicKeyPath, $snapshotSourcePublicKey, $false)
    $snapshotPublicKeyText = Get-UpdaterPublicKeyText -LiteralPath $snapshotSourcePublicKey
    $snapshotFingerprint = Get-UpdaterPublicKeyTextFingerprint -PublicKeyText $snapshotPublicKeyText
    [void](Write-UpdaterPublicKeySnapshot -PublicKeyText $snapshotPublicKeyText -LiteralPath $snapshotPublicKey)
    [System.IO.File]::Copy(($temporaryKeyTwo + '.pub'), $snapshotSourcePublicKey, $true)
    Test-Equal 'Public-key snapshot fingerprint survives replacement of the external source path' $snapshotFingerprint `
        (Get-UpdaterPublicKeyFingerprint -LiteralPath $snapshotPublicKey)
    Test-Equal 'Public-key snapshot still verifies the artifact after external source replacement' $true `
        (Test-UpdaterArtifactSignature -ArtifactPath $artifactPath -SignaturePath $signaturePath -PublicKeyPath $snapshotPublicKey)
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
    $invalidSizeLatestPath = [System.IO.Path]::Combine($temporaryRoot, 'invalid-string-size.json')
    $invalidSizeDocument = [ordered]@{
        version='0.2.0-beta.1'; notes=''; pub_date=[DateTimeOffset]::UtcNow.ToString('o');
        platforms=[ordered]@{ 'windows-x86_64'=[ordered]@{ signature=$signature; url='https://updates.qijiang-desktop-pet.com/files/qijiang.exe'; size='9' } }
    }
    [System.IO.File]::WriteAllText($invalidSizeLatestPath, ($invalidSizeDocument | ConvertTo-Json -Depth 6), $utf8NoBom)
    Test-Throws 'latest.json rejects a string artifact size' {
        Test-UpdaterLatestDocument -LatestJsonPath $invalidSizeLatestPath -CurrentVersion '0.1.0'
    } 'invalid artifact size'
    $extraPropertyLatestPath = [System.IO.Path]::Combine($temporaryRoot, 'invalid-extra-property.json')
    $extraPropertyDocument = [ordered]@{
        version='0.2.0-beta.1'; notes=''; pub_date=[DateTimeOffset]::UtcNow.ToString('o'); unexpected='blocked';
        platforms=[ordered]@{ 'windows-x86_64'=[ordered]@{ signature=$signature; url='https://updates.qijiang-desktop-pet.com/files/qijiang.exe'; size=9 } }
    }
    [System.IO.File]::WriteAllText($extraPropertyLatestPath, ($extraPropertyDocument | ConvertTo-Json -Depth 6), $utf8NoBom)
    Test-Throws 'latest.json rejects unknown top-level properties' {
        Test-UpdaterLatestDocument -LatestJsonPath $extraPropertyLatestPath -CurrentVersion '0.1.0'
    } 'must contain exactly'
    $invalidDateLatestPath = [System.IO.Path]::Combine($temporaryRoot, 'invalid-date.json')
    $invalidDateDocument = [ordered]@{
        version='0.2.0-beta.1'; notes=''; pub_date='2026/07/16';
        platforms=[ordered]@{ 'windows-x86_64'=[ordered]@{ signature=$signature; url='https://updates.qijiang-desktop-pet.com/files/qijiang.exe'; size=9 } }
    }
    [System.IO.File]::WriteAllText($invalidDateLatestPath, ($invalidDateDocument | ConvertTo-Json -Depth 6), $utf8NoBom)
    Test-Throws 'latest.json rejects non-RFC3339 publication times' {
        Test-UpdaterLatestDocument -LatestJsonPath $invalidDateLatestPath -CurrentVersion '0.1.0'
    } 'RFC3339'
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
    $sensitiveHttpUrl = 'http://updates.qijiang-desktop-pet.com/file.exe?' + (-join @('to','ken=must-not-echo'))
    $sensitiveHttpError = ''
    try { Assert-UpdaterHttpsUrl -Url $sensitiveHttpUrl | Out-Null } catch { $sensitiveHttpError = [string]$_.Exception.Message }
    Test-True 'Rejected HTTP updater URLs return a safe error' (-not [string]::IsNullOrWhiteSpace($sensitiveHttpError)) 'An error is required.'
    Test-Equal 'Rejected HTTP updater URLs do not echo credentials' $false ([bool]$sensitiveHttpError.Contains('must-not-echo'))
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
    Test-Throws 'Metadata rejects quoted token fields' { Assert-NoUpdaterSensitiveMetadata -Text '{"refreshToken":"must-not-pass"}' } 'sensitive|secret'
    Test-Throws 'Metadata rejects nested credential fields' { Assert-NoUpdaterSensitiveMetadata -Text '{"outer":{"credential":"must-not-pass"}}' } 'sensitive|secret'
    $quotedPasswordMetadata = -join @('prefix "','pass','word"="','must','-not-pass" suffix')
    Test-Throws 'Non-JSON metadata rejects quoted password fields' {
        Assert-NoUpdaterSensitiveMetadata -Text $quotedPasswordMetadata
    } 'local path or secret'
    $classicGitHubToken = -join @('g','hp','_',('A' * 36))
    $fineGrainedGitHubToken = -join @('github','_pat','_',('B' * 48))
    $bearerToken = -join @('Bear','er ',('C' * 40))
    foreach ($sensitiveValueCase in @(
        [pscustomobject]@{ Name='classic GitHub token'; Value=$classicGitHubToken },
        [pscustomobject]@{ Name='fine-grained GitHub token'; Value=$fineGrainedGitHubToken },
        [pscustomobject]@{ Name='Bearer token'; Value=$bearerToken }
    )) {
        $metadataWithSensitiveValue = [ordered]@{ status=[string]$sensitiveValueCase.Value } | ConvertTo-Json -Compress
        $sensitiveValueError = ''
        try { Assert-NoUpdaterSensitiveMetadata -Text $metadataWithSensitiveValue }
        catch { $sensitiveValueError = [string]$_.Exception.Message }
        Test-True ("Metadata rejects " + [string]$sensitiveValueCase.Name + ' in an allowed field') `
            (-not [string]::IsNullOrWhiteSpace($sensitiveValueError)) $sensitiveValueError
        Test-Equal ("Metadata error redacts " + [string]$sensitiveValueCase.Name) $false `
            ([bool]$sensitiveValueError.Contains([string]$sensitiveValueCase.Value))
    }

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

    $backupSourceDirectory = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x5BC6,[char]0x94A5,' source')))
    $backupDirectoryOne = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x79BB,[char]0x7EBF,' backup one')))
    $backupDirectoryTwo = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x79BB,[char]0x7EBF,' backup two')))
    [void][System.IO.Directory]::CreateDirectory($backupSourceDirectory)
    $backupPrivateKey = [System.IO.Path]::Combine($backupSourceDirectory, 'qijiang-production.key')
    $backupPublicKey = $backupPrivateKey + '.pub'
    [System.IO.File]::WriteAllText($backupPrivateKey, "untrusted comment: rsign encrypted secret key`nfixture-backup-container", $utf8NoBom)
    [System.IO.File]::Copy($publicKeyPath, $backupPublicKey, $false)
    $separateVolumeResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            return [pscustomobject]@{ Identity='test-disk-source'; Verified=$true; Description='fixed test disk'; Removable=$false }
        }
        if ([System.IO.Path]::GetFileName($Path) -match 'one$') {
            return [pscustomobject]@{ Identity='test-disk-backup-one'; Verified=$true; Description='USB test disk'; Removable=$true }
        }
        return [pscustomobject]@{ Identity='test-disk-backup-two'; Verified=$true; Description='USB test disk'; Removable=$true }
    }.GetNewClosure()
    $sameBackupDiskResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            return [pscustomobject]@{ Identity='test-disk-source'; Verified=$true; Description='fixed test disk'; Removable=$false }
        }
        return [pscustomobject]@{ Identity='test-disk-shared-backup'; Verified=$true; Description='USB test disk'; Removable=$true }
    }.GetNewClosure()
    $activeUpdaterTestMode = [Environment]::GetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', $previousUpdaterTestMode, 'Process')
        Test-Throws 'Custom volume resolvers are rejected outside the isolated updater test mode' {
            Get-UpdaterBackupVolumeIdentity -Path $backupPrivateKey -VolumeResolver $separateVolumeResolver
        } 'available only to the isolated updater regression test'
    } finally {
        [Environment]::SetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', $activeUpdaterTestMode, 'Process')
    }
    $stringBooleanResolver = {
        param([string]$Path)
        return [pscustomobject]@{
            Identity = 'string-boolean-' + [System.IO.Path]::GetFileName($Path)
            Verified = 'false'
            Description = 'invalid test volume flags'
            Removable = 'false'
        }
    }
    Test-Throws 'String false cannot pass strict physical-volume verification' {
        New-UpdaterKeyBackupPlan -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $backupDirectoryOne -BackupDirectoryTwo $backupDirectoryTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $stringBooleanResolver
    } 'strict Boolean Verified and Removable'
    Test-Equal 'Volume-root normalization preserves its trailing directory separator' 'G:\' (Normalize-UpdaterDirectoryPath -Path 'G:\')
    Test-Equal 'Combining a normalized volume root produces an absolute child path' 'G:\qijiang-production.key' `
        ([System.IO.Path]::Combine((Normalize-UpdaterDirectoryPath -Path 'G:\'), 'qijiang-production.key'))
    foreach ($virtualBusType in @('Virtual', 'File Backed Virtual', 'Storage Spaces', 'Unknown', 'iSCSI', 'RAID')) {
        Test-Equal "Non-physical updater backup bus is rejected: $virtualBusType" $false (Test-UpdaterPhysicalBusType -BusType $virtualBusType)
    }
    foreach ($physicalBusType in @('USB', 'SD', 'MMC', 'SATA', 'NVMe')) {
        Test-Equal "Physical updater backup bus is recognized: $physicalBusType" $true (Test-UpdaterPhysicalBusType -BusType $physicalBusType)
    }
    Test-Equal 'A disk number alone is not accepted as a stable physical identity' $null `
        (Get-UpdaterStableDiskIdentity -Disk ([pscustomobject]@{ UniqueId=''; SerialNumber=''; Number=7 }))
    Test-Equal 'A non-empty disk UniqueId is accepted as a stable physical identity' 'unique:stable-id' `
        (Get-UpdaterStableDiskIdentity -Disk ([pscustomobject]@{ UniqueId=' stable-id '; SerialNumber='serial-fallback'; Number=7 }))
    Test-Equal 'A serial number is the stable fallback when UniqueId is empty' 'serial:stable-serial' `
        (Get-UpdaterStableDiskIdentity -Disk ([pscustomobject]@{ UniqueId=''; SerialNumber=' stable-serial '; Number=7 }))
    Test-Throws 'Two directories on the same physical disk are not accepted as independent backups' {
        New-UpdaterKeyBackupPlan -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $backupDirectoryOne -BackupDirectoryTwo $backupDirectoryTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $sameBackupDiskResolver
    } 'three separate physical disks'
    $unverifiedVolumeResolver = {
        param([string]$Path)
        return [pscustomobject]@{ Identity=('unverified-' + [System.IO.Path]::GetFileName($Path)); Verified=$false; Description='unknown test volume'; Removable=$false }
    }
    Test-Throws 'Backup stops when physical disk separation cannot be proved' {
        New-UpdaterKeyBackupPlan -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $backupDirectoryOne -BackupDirectoryTwo $backupDirectoryTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $unverifiedVolumeResolver
    } 'Unable to prove'
    $fixedBackupResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            return [pscustomobject]@{ Identity='test-disk-source'; Verified=$true; Description='NVMe physical disk'; Removable=$false }
        }
        if ([System.IO.Path]::GetFileName($Path) -match 'one$') {
            return [pscustomobject]@{ Identity='test-fixed-backup-one'; Verified=$true; Description='SATA physical disk'; Removable=$false }
        }
        return [pscustomobject]@{ Identity='test-fixed-backup-two'; Verified=$true; Description='SATA physical disk'; Removable=$false }
    }.GetNewClosure()
    Test-Throws 'Fixed internal disks cannot be counted as offline backup targets' {
        New-UpdaterKeyBackupPlan -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $backupDirectoryOne -BackupDirectoryTwo $backupDirectoryTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $fixedBackupResolver
    } 'must be USB, SD, MMC, or Windows removable-drive media'
    $fileReparseResolver = {
        param([string]$Path)
        if ([string]::Equals($Path, $backupPrivateKey, [StringComparison]::OrdinalIgnoreCase)) {
            return [System.IO.FileAttributes]::ReparsePoint
        }
        return [System.IO.FileAttributes]::Normal
    }.GetNewClosure()
    Test-Throws 'The private-key file itself cannot be a symbolic link or other reparse point' {
        Assert-NoUpdaterBackupReparsePoint -Path $backupPrivateKey -AttributeResolver $fileReparseResolver
    } 'must not traverse symbolic links'
    $parentReparseResolver = {
        param([string]$Path)
        if ([string]::Equals($Path, $backupSourceDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            return [System.IO.FileAttributes]::ReparsePoint
        }
        return [System.IO.FileAttributes]::Normal
    }.GetNewClosure()
    Test-Throws 'The key file immediate parent directory cannot be a junction' {
        Assert-NoUpdaterBackupReparsePoint -Path $backupPrivateKey -AttributeResolver $parentReparseResolver
    } 'must not traverse symbolic links'
    $backupResult = Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
        -BackupDirectoryOne $backupDirectoryOne -BackupDirectoryTwo $backupDirectoryTwo `
        -RepositoryRoot $repositoryRoot -VolumeResolver $separateVolumeResolver -Confirm:$false
    Test-Equal 'Unicode and space-containing backup paths complete' 'Completed' ([string]$backupResult.Mode)
    foreach ($backupDirectory in @($backupDirectoryOne, $backupDirectoryTwo)) {
        $privateBackup = [System.IO.Path]::Combine($backupDirectory, [System.IO.Path]::GetFileName($backupPrivateKey))
        $publicBackup = [System.IO.Path]::Combine($backupDirectory, [System.IO.Path]::GetFileName($backupPublicKey))
        Test-Equal 'Private-key backup hash matches its source' (Get-UpdaterBackupFileHash -LiteralPath $backupPrivateKey) (Get-UpdaterBackupFileHash -LiteralPath $privateBackup)
        Test-Equal 'Public-key backup hash matches its source' (Get-UpdaterBackupFileHash -LiteralPath $backupPublicKey) (Get-UpdaterBackupFileHash -LiteralPath $publicBackup)
    }
    $serializedBackupResult = $backupResult | ConvertTo-Json -Depth 6 -Compress
    Test-Equal 'Backup result does not reveal the full source path' $false ([bool]$serializedBackupResult.Contains($temporaryRoot))
    Test-Equal 'Backup result does not reveal private-key content' $false ([bool]($serializedBackupResult -match 'fixture-backup-container'))
    Test-Throws 'Existing backup files are never overwritten' {
        Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $backupDirectoryOne -BackupDirectoryTwo $backupDirectoryTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $separateVolumeResolver -Confirm:$false
    } 'Refusing to overwrite'

    $previewBackupOne = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x9884,[char]0x89C8,' backup one')))
    $previewBackupTwo = [System.IO.Path]::Combine($temporaryRoot, (-join @([char]0x9884,[char]0x89C8,' backup two')))
    $previewResult = Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
        -BackupDirectoryOne $previewBackupOne -BackupDirectoryTwo $previewBackupTwo `
        -RepositoryRoot $repositoryRoot -VolumeResolver $separateVolumeResolver -WhatIf -Confirm:$false
    Test-Equal 'Updater key backup WhatIf returns preview mode' 'PreviewOnly' ([string]$previewResult.Mode)
    Test-Equal 'Updater key backup WhatIf creates no first directory' $false ([System.IO.Directory]::Exists($previewBackupOne))
    Test-Equal 'Updater key backup WhatIf creates no second directory' $false ([System.IO.Directory]::Exists($previewBackupTwo))

    $revalidationDirectoryOne = [System.IO.Path]::Combine($temporaryRoot, 'revalidation backup one')
    $revalidationDirectoryTwo = [System.IO.Path]::Combine($temporaryRoot, 'revalidation backup two')
    $revalidationState = [pscustomobject]@{ Snapshots = 0 }
    $changingVolumeResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            $revalidationState.Snapshots++
            return [pscustomobject]@{
                Identity='test-disk-source'
                Verified=($revalidationState.Snapshots -le 4)
                Description='fixed test disk'
                Removable=$false
            }
        }
        if ([System.IO.Path]::GetFileName($Path) -match 'one$') {
            return [pscustomobject]@{ Identity='test-disk-backup-one'; Verified=$true; Description='USB test disk'; Removable=$true }
        }
        return [pscustomobject]@{ Identity='test-disk-backup-two'; Verified=$true; Description='USB test disk'; Removable=$true }
    }.GetNewClosure()
    Test-Throws 'Backup revalidates the complete storage snapshot immediately before the first copy' {
        Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $revalidationDirectoryOne -BackupDirectoryTwo $revalidationDirectoryTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $changingVolumeResolver -Confirm:$false
    } 'Unable to prove'
    Test-Equal 'Backup rechecked both source files while establishing the post-confirmation baseline' 6 $revalidationState.Snapshots
    Test-Equal 'Failed pre-copy revalidation leaves no first backup directory' $false ([System.IO.Directory]::Exists($revalidationDirectoryOne))
    Test-Equal 'Failed pre-copy revalidation leaves no second backup directory' $false ([System.IO.Directory]::Exists($revalidationDirectoryTwo))

    $copyGatePath = [System.IO.Path]::Combine($temporaryRoot, 'copy-action-gate.key')
    $copyGateAction = { param([string]$SourcePath, [string]$DestinationPath) [System.IO.File]::Copy($SourcePath, $DestinationPath, $false) }
    $activeUpdaterTestMode = [Environment]::GetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', $previousUpdaterTestMode, 'Process')
        Test-Throws 'Direct custom backup copy actions are rejected outside isolated test mode' {
            Copy-UpdaterBackupFileVerified -SourcePath $backupPrivateKey -DestinationPath $copyGatePath -CopyAction $copyGateAction
        } 'available only to the isolated updater regression test'
        Test-Throws 'Production-reachable backup copy actions are rejected outside isolated test mode' {
            Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
                -BackupDirectoryOne $previewBackupOne -BackupDirectoryTwo $previewBackupTwo `
                -RepositoryRoot $repositoryRoot -VolumeResolver $null -CopyAction $copyGateAction -Confirm:$false
        } 'available only to the isolated updater regression test'
    } finally {
        [Environment]::SetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', $activeUpdaterTestMode, 'Process')
    }
    Test-Equal 'Rejected custom copy action creates no file' $false ([System.IO.File]::Exists($copyGatePath))

    $targetSwitchOne = [System.IO.Path]::Combine($temporaryRoot, 'target-switch-one')
    $targetSwitchTwo = [System.IO.Path]::Combine($temporaryRoot, 'target-switch-two')
    $targetSwitchState = [pscustomobject]@{ TargetOne='target-switch-disk-one'; Copies=0 }
    $targetSwitchResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            return [pscustomobject]@{ Identity='target-switch-source'; Verified=$true; Description='fixed test disk'; Removable=$false }
        }
        if (Test-PathWithinDirectory -Path $Path -Directory $targetSwitchOne) {
            return [pscustomobject]@{ Identity=$targetSwitchState.TargetOne; Verified=$true; Description='USB test disk'; Removable=$true }
        }
        return [pscustomobject]@{ Identity='target-switch-disk-two'; Verified=$true; Description='USB test disk'; Removable=$true }
    }.GetNewClosure()
    $targetSwitchCopy = {
        param([string]$SourcePath, [string]$DestinationPath)
        [System.IO.File]::Copy($SourcePath, $DestinationPath, $false)
        $targetSwitchState.Copies++
        if ($targetSwitchState.Copies -eq 1) { $targetSwitchState.TargetOne = 'target-switch-replacement' }
    }.GetNewClosure()
    Test-Throws 'A target-medium switch after the first copy stops backup and automatic cleanup' {
        Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $targetSwitchOne -BackupDirectoryTwo $targetSwitchTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $targetSwitchResolver -CopyAction $targetSwitchCopy -Confirm:$false
    } 'automatic cleanup was stopped because storage identity or path safety changed'
    $targetSwitchPrivate = [System.IO.Path]::Combine($targetSwitchOne, [System.IO.Path]::GetFileName($backupPrivateKey))
    Test-Equal 'Target switch preserves the prior created file for manual inspection' $true ([System.IO.File]::Exists($targetSwitchPrivate))
    Test-Equal 'Target switch never reports or produces the complete first backup pair' $false `
        ([System.IO.File]::Exists([System.IO.Path]::Combine($targetSwitchOne, [System.IO.Path]::GetFileName($backupPublicKey))))

    $sourceSwitchOne = [System.IO.Path]::Combine($temporaryRoot, 'source-switch-one')
    $sourceSwitchTwo = [System.IO.Path]::Combine($temporaryRoot, 'source-switch-two')
    $sourceSwitchState = [pscustomobject]@{ Source='source-switch-original'; Copies=0 }
    $sourceSwitchResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            return [pscustomobject]@{ Identity=$sourceSwitchState.Source; Verified=$true; Description='fixed test disk'; Removable=$false }
        }
        if (Test-PathWithinDirectory -Path $Path -Directory $sourceSwitchOne) {
            return [pscustomobject]@{ Identity='source-switch-target-one'; Verified=$true; Description='USB test disk'; Removable=$true }
        }
        return [pscustomobject]@{ Identity='source-switch-target-two'; Verified=$true; Description='USB test disk'; Removable=$true }
    }.GetNewClosure()
    $sourceSwitchCopy = {
        param([string]$SourcePath, [string]$DestinationPath)
        [System.IO.File]::Copy($SourcePath, $DestinationPath, $false)
        $sourceSwitchState.Copies++
        if ($sourceSwitchState.Copies -eq 1) { $sourceSwitchState.Source = 'source-switch-replacement' }
    }.GetNewClosure()
    Test-Throws 'A source-medium switch after the first copy stops backup and automatic cleanup' {
        Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $sourceSwitchOne -BackupDirectoryTwo $sourceSwitchTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $sourceSwitchResolver -CopyAction $sourceSwitchCopy -Confirm:$false
    } 'automatic cleanup was stopped because storage identity or path safety changed'
    Test-Equal 'Source switch preserves the prior created file for manual inspection' $true `
        ([System.IO.File]::Exists([System.IO.Path]::Combine($sourceSwitchOne, [System.IO.Path]::GetFileName($backupPrivateKey))))

    $cleanupSwitchOne = [System.IO.Path]::Combine($temporaryRoot, 'cleanup-switch-one')
    $cleanupSwitchTwo = [System.IO.Path]::Combine($temporaryRoot, 'cleanup-switch-two')
    $cleanupSwitchState = [pscustomobject]@{ TargetOne='cleanup-switch-original'; Copies=0 }
    $cleanupSwitchResolver = {
        param([string]$Path)
        if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
            return [pscustomobject]@{ Identity='cleanup-switch-source'; Verified=$true; Description='fixed test disk'; Removable=$false }
        }
        if (Test-PathWithinDirectory -Path $Path -Directory $cleanupSwitchOne) {
            return [pscustomobject]@{ Identity=$cleanupSwitchState.TargetOne; Verified=$true; Description='USB test disk'; Removable=$true }
        }
        return [pscustomobject]@{ Identity='cleanup-switch-target-two'; Verified=$true; Description='USB test disk'; Removable=$true }
    }.GetNewClosure()
    $cleanupSwitchCopy = {
        param([string]$SourcePath, [string]$DestinationPath)
        $cleanupSwitchState.Copies++
        if ($cleanupSwitchState.Copies -eq 1) {
            [System.IO.File]::Copy($SourcePath, $DestinationPath, $false)
            return
        }
        $cleanupSwitchState.TargetOne = 'cleanup-switch-replacement'
        throw 'synthetic copy failure before cleanup'
    }.GetNewClosure()
    Test-Throws 'A target-medium switch immediately before failure cleanup stops automatic deletion' {
        Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
            -BackupDirectoryOne $cleanupSwitchOne -BackupDirectoryTwo $cleanupSwitchTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $cleanupSwitchResolver -CopyAction $cleanupSwitchCopy -Confirm:$false
    } 'automatic cleanup was stopped because storage identity or path safety changed'
    Test-Equal 'Cleanup-time switch cannot delete a same-path file on the replacement identity' $true `
        ([System.IO.File]::Exists([System.IO.Path]::Combine($cleanupSwitchOne, [System.IO.Path]::GetFileName($backupPrivateKey))))

    foreach ($switchFailureMode in @('ThrowAfterCreate', 'HashMismatchAfterCreate')) {
        $duringCopyOne = [System.IO.Path]::Combine($temporaryRoot, "during-copy-$switchFailureMode-one")
        $duringCopyTwo = [System.IO.Path]::Combine($temporaryRoot, "during-copy-$switchFailureMode-two")
        $duringCopyState = [pscustomobject]@{ TargetOne="during-copy-$switchFailureMode-original" }
        $duringCopyResolver = {
            param([string]$Path)
            if (Test-PathWithinDirectory -Path $Path -Directory $backupSourceDirectory) {
                return [pscustomobject]@{ Identity="during-copy-$switchFailureMode-source"; Verified=$true; Description='fixed test disk'; Removable=$false }
            }
            if (Test-PathWithinDirectory -Path $Path -Directory $duringCopyOne) {
                return [pscustomobject]@{ Identity=$duringCopyState.TargetOne; Verified=$true; Description='USB test disk'; Removable=$true }
            }
            return [pscustomobject]@{ Identity="during-copy-$switchFailureMode-target-two"; Verified=$true; Description='USB test disk'; Removable=$true }
        }.GetNewClosure()
        $duringCopyAction = {
            param([string]$SourcePath, [string]$DestinationPath)
            if ($switchFailureMode -eq 'ThrowAfterCreate') {
                [System.IO.File]::Copy($SourcePath, $DestinationPath, $false)
            } else {
                [System.IO.File]::WriteAllBytes($DestinationPath, [byte[]](9,8,7,6))
            }
            $duringCopyState.TargetOne = "during-copy-$switchFailureMode-replacement"
            if ($switchFailureMode -eq 'ThrowAfterCreate') {
                throw 'synthetic copy error after destination creation and medium switch'
            }
        }.GetNewClosure()
        Test-Throws "A medium switch during $switchFailureMode stops low-level destination cleanup" {
            Invoke-UpdaterKeyBackup -PrivateKeyPath $backupPrivateKey -PublicKeyPath $backupPublicKey `
                -BackupDirectoryOne $duringCopyOne -BackupDirectoryTwo $duringCopyTwo `
                -RepositoryRoot $repositoryRoot -VolumeResolver $duringCopyResolver -CopyAction $duringCopyAction -Confirm:$false
        } 'automatic cleanup was stopped because storage identity or path safety changed'
        $duringCopyDestination = [System.IO.Path]::Combine($duringCopyOne, [System.IO.Path]::GetFileName($backupPrivateKey))
        Test-Equal "A replacement-identity same-path file is retained after $switchFailureMode" $true `
            ([System.IO.File]::Exists($duringCopyDestination))
    }

    $corruptCopyDirectory = [System.IO.Path]::Combine($temporaryRoot, 'corrupt-copy-test')
    [void][System.IO.Directory]::CreateDirectory($corruptCopyDirectory)
    $corruptCopyPath = [System.IO.Path]::Combine($corruptCopyDirectory, 'qijiang-production.key')
    $corruptCopyAction = {
        param([string]$SourcePath, [string]$DestinationPath)
        [System.IO.File]::WriteAllBytes($DestinationPath, [byte[]](1,2,3,4))
    }
    Test-Throws 'Backup copy SHA-256 verification rejects changed bytes' {
        Copy-UpdaterBackupFileVerified -SourcePath $backupPrivateKey -DestinationPath $corruptCopyPath -CopyAction $corruptCopyAction
    } 'unverified destination was left for manual inspection'
    Test-Equal 'Low-level helper never deletes a hash-mismatched copy without baseline authorization' $true ([System.IO.File]::Exists($corruptCopyPath))
    [System.IO.File]::Delete($corruptCopyPath)
    $leakyCopyPath = [System.IO.Path]::Combine($corruptCopyDirectory, 'leaky-copy.key')
    $leakyCopyAction = {
        param([string]$SourcePath, [string]$DestinationPath)
        throw "Access denied while copying to $DestinationPath"
    }
    $leakyCopyError = ''
    try {
        Copy-UpdaterBackupFileVerified -SourcePath $backupPrivateKey -DestinationPath $leakyCopyPath -CopyAction $leakyCopyAction | Out-Null
    } catch { $leakyCopyError = [string]$_.Exception.Message }
    Test-Equal 'Unexpected copy IO errors are converted to a safe error' 'Updater key backup copy or verification failed.' $leakyCopyError
    Test-Equal 'Unexpected copy IO errors do not reveal an absolute path' $false ([bool]$leakyCopyError.Contains($temporaryRoot))
    $cleanupFailurePath = [System.IO.Path]::Combine($corruptCopyDirectory, 'cleanup-failure.key')
    $script:cleanupFailureLock = $null
    $cleanupFailureAction = {
        param([string]$SourcePath, [string]$DestinationPath)
        [System.IO.File]::WriteAllBytes($DestinationPath, [byte[]](7,7,7))
        $script:cleanupFailureLock = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        throw "Simulated IO failure at $DestinationPath"
    }
    try {
        $cleanupFailureError = ''
        try {
            Copy-UpdaterBackupFileVerified -SourcePath $backupPrivateKey -DestinationPath $cleanupFailurePath -CopyAction $cleanupFailureAction | Out-Null
        } catch { $cleanupFailureError = [string]$_.Exception.Message }
        Test-Equal 'Cleanup IO errors are converted to a safe recovery instruction' `
            'Updater key backup verification failed and the unverified destination was left for manual inspection.' $cleanupFailureError
        Test-Equal 'Cleanup IO errors do not reveal an absolute path' $false ([bool]$cleanupFailureError.Contains($temporaryRoot))
    } finally {
        if ($null -ne $script:cleanupFailureLock) { $script:cleanupFailureLock.Dispose(); $script:cleanupFailureLock = $null }
        if ([System.IO.File]::Exists($cleanupFailurePath)) { [System.IO.File]::Delete($cleanupFailurePath) }
    }
    $lockedHashPath = [System.IO.Path]::Combine($corruptCopyDirectory, 'locked-hash.key')
    [System.IO.File]::Copy($backupPrivateKey, $lockedHashPath, $false)
    $exclusiveStream = [System.IO.File]::Open($lockedHashPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $lockedHashError = ''
        try { Get-UpdaterBackupFileHash -LiteralPath $lockedHashPath | Out-Null } catch { $lockedHashError = [string]$_.Exception.Message }
        Test-Equal 'Hash IO errors are converted to a safe error' 'Unable to read an updater key backup file for SHA-256 verification.' $lockedHashError
        Test-Equal 'Hash IO errors do not reveal an absolute path' $false ([bool]$lockedHashError.Contains($temporaryRoot))
    } finally {
        $exclusiveStream.Dispose()
    }
    Test-Throws 'Backup public-key source inside the repository is rejected' {
        New-UpdaterKeyBackupPlan -PrivateKeyPath $backupPrivateKey -PublicKeyPath ([System.IO.Path]::Combine($repositoryRoot, 'unsafe.key.pub')) `
            -BackupDirectoryOne $previewBackupOne -BackupDirectoryTwo $previewBackupTwo `
            -RepositoryRoot $repositoryRoot -VolumeResolver $separateVolumeResolver
    } 'public key source.*outside the repository'
    $backupScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'backup-updater-key.ps1')) -Raw -Encoding UTF8
    Test-True 'Backup script exposes SupportsShouldProcess for WhatIf' ([bool]($backupScriptText -match 'SupportsShouldProcess\s*=\s*\$true')) 'SupportsShouldProcess'

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
    $buildPlan = & ([System.IO.Path]::Combine($updaterTools, 'build-signed-update.ps1')) -Version $configuredApplicationVersion `
        -EndpointBaseUrl 'https://updates.qijiang-desktop-pet.com/qijiang/' -PrivateKeyPath $previewKeyPath `
        -OutputDirectory ([System.IO.Path]::Combine($temporaryRoot, 'signed build preview')) -Execute -WhatIf
    Test-Equal 'Signed build defaults to preview mode' 'PreviewOnly' ([string]$buildPlan.Mode)
    Test-Equal 'Signed build preview preserves private-key environment' $previousKeyEnvironment ([Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process'))
    Test-Equal 'Signed build preview preserves password environment' $previousPasswordEnvironment ([Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process'))
    Test-Equal 'Signed build preview preserves runtime endpoint environment' $previousRuntimeEndpoint ([Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_ENDPOINT', 'Process'))
    Test-Equal 'Signed build preview preserves runtime public-key environment' $previousRuntimePublicKey ([Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_PUBLIC_KEY', 'Process'))
    Test-Equal 'Signed build preview preserves runtime channel environment' $previousRuntimeChannel ([Environment]::GetEnvironmentVariable('QIJIANG_UPDATER_CHANNEL', 'Process'))
    $signedBuildScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'build-signed-update.ps1')) -Raw -Encoding UTF8
    Test-True 'Signed build uses an isolated Cargo target directory' `
        ([bool]($signedBuildScriptText -match "SetEnvironmentVariable\('CARGO_TARGET_DIR'" -and $signedBuildScriptText -match 'isolatedTargetDirectory')) `
        'Each signed build must bind artifacts from a fresh target directory.'
    Test-True 'Signed build requires the exact product, version, and architecture filename' `
        ([bool]($signedBuildScriptText -match '(?s)Get-ExactUpdaterInstallerArtifact.*productName.*Version')) `
        'A newest-file heuristic must not bind a stale artifact to HEAD.'
    Test-True 'Signed build verifies the copied destination artifact' `
        ([bool]($signedBuildScriptText -match 'Test-UpdaterArtifactSignature\s+-ArtifactPath\s+\$artifactDestination')) `
        'The final copied bytes are the bytes recorded in the manifest.'
    Test-True 'Signed build publishes only by moving its unique staging directory' `
        ([bool]($signedBuildScriptText -match '\.staging-' -and $signedBuildScriptText -match '\[System\.IO\.Directory\]::Move\(\$stagedOutput, \$output\)' -and $signedBuildScriptText -notmatch 'Directory\]::Delete\(\$output')) `
        'A colliding user output directory is never recursively deleted.'
    $prepareScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'prepare-updater-release.ps1')) -Raw -Encoding UTF8
    Test-True 'Release preparation publishes a fully verified unique staging directory atomically' `
        ([bool]($prepareScriptText -match '\.staging-' -and $prepareScriptText -match 'Directory\]::Move\(\$stagingDirectory, \$versionDirectory\)' -and $prepareScriptText -match '\$publishedVersionDirectory')) `
        'Failure cleanup is gated by ownership established by the successful move.'
    $prepareCopyIndex = $prepareScriptText.IndexOf('[System.IO.File]::Copy($artifact, $artifactDestination')
    $prepareDestinationSignatureIndex = $prepareScriptText.IndexOf('Get-UpdaterSignatureText -SignaturePath $signatureDestination')
    $prepareDocumentIndex = $prepareScriptText.IndexOf('$document = New-UpdaterLatestDocument')
    Test-True 'Release metadata is derived only from the copied staging artifact and signature' `
        ($prepareCopyIndex -ge 0 -and $prepareDestinationSignatureIndex -gt $prepareCopyIndex -and $prepareDocumentIndex -gt $prepareDestinationSignatureIndex -and `
         $prepareScriptText -notmatch 'Get-UpdaterSignatureText\s+-SignaturePath\s+\$signatureFile') `
        'Source files must not be pre-read into metadata before the immutable staging copy exists.'
    Test-True 'Release preparation rechecks Git state before metadata publication' `
        ([regex]::Matches($prepareScriptText, 'Assert-UpdaterGitStateUnchanged').Count -ge 2) `
        'Both manifest creation and atomic publication must remain bound to one Git snapshot.'
    Test-True 'Signed updater builds recheck a clean Git snapshot before atomic publication' `
        ([regex]::Matches($signedBuildScriptText, 'Assert-UpdaterGitStateUnchanged').Count -ge 2 -and `
         $signedBuildScriptText -match 'Assert-UpdaterGitStateUnchanged\s+-InitialState\s+\$gitState\s+-RequireClean') `
        'Long signed builds must not publish after HEAD or worktree drift.'
    Test-True 'Release preparation uses one immutable public-key snapshot for fingerprint and verification' `
        ([bool]($prepareScriptText -match 'Get-UpdaterPublicKeyTextFingerprint\s+-PublicKeyText\s+\$publicKeyText' -and `
                 $prepareScriptText -match 'Test-UpdaterArtifactSignature(?s).*?-PublicKeyPath\s+\$publicKeySnapshot')) `
        'External public-key replacement must not split fingerprint and cryptographic verification.'
    Test-True 'Signed build reuses one public-key snapshot and rechecks private-key bytes' `
        ([bool]($signedBuildScriptText -match 'Write-UpdaterPublicKeySnapshot' -and `
                 $signedBuildScriptText -match 'Test-UpdaterArtifactSignature(?s).*?-PublicKeyPath\s+\$publicKeySnapshot' -and `
                 [regex]::Matches($signedBuildScriptText, 'Get-Sha256Hex\s+-LiteralPath\s+\$privateKey').Count -ge 3)) `
        'Overlay, signature verification, manifest fingerprint, and private-key identity must stay bound.'
    $initializeScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'initialize-updater-key.ps1')) -Raw -Encoding UTF8
    Test-True 'Key initialization generates into owned staging files before publication' `
        ([bool]($initializeScriptText -match '\$stagingPrivateKeyPath' -and `
                 $initializeScriptText -match 'File\]::Move\(\$stagingPrivateKeyPath, \$privateKeyPath\)' -and `
                 $initializeScriptText -match '\$publishedPrivateKey\s*=\s*\$true')) `
        'Failure cleanup must never delete a key file created concurrently by another process.'
    Test-True 'Key initialization publishes the non-secret public key before the private key' `
        ($initializeScriptText.IndexOf('File]::Move($stagingPublicKeyPath, $publicKeyPath)') -lt `
         $initializeScriptText.IndexOf('File]::Move($stagingPrivateKeyPath, $privateKeyPath)')) `
        'A process interruption must not leave only a private key at the final path.'
    $commonScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'common.ps1')) -Raw -Encoding UTF8
    Test-True 'Git snapshot fingerprints include untracked file bytes' `
        ([bool]($commonScriptText -match 'ls-files\s+--others\s+--exclude-standard' -and `
                 $commonScriptText -match '\$untrackedFingerprints' -and `
                 $commonScriptText -match 'Get-Sha256Hex\s+-LiteralPath\s+\$absolutePath')) `
        'Dirty release preparation must detect content drift at an existing untracked path.'
    Test-True 'Atomic latest publication cannot throw a stoppable warning after commit' `
        ([bool]($commonScriptText -match 'CleanupPending=\$cleanupPending' -and `
                 $commonScriptText -notmatch "Write-Warning 'Updater pointer replacement succeeded")) `
        'A post-commit cleanup notice must not trigger rollback through WarningAction Stop.'
    Test-True 'Published immutable version directories are never deleted during pointer recovery' `
        ([bool]($prepareScriptText -notmatch 'Directory\]::Delete\(\$versionDirectory')) `
        'An unexpected post-commit failure must not create a dangling top-level latest pointer.'
    $gitFingerprintFixture = [System.IO.Path]::Combine($temporaryRoot, 'git-fingerprint-fixture')
    [void][System.IO.Directory]::CreateDirectory($gitFingerprintFixture)
    & git -C $gitFingerprintFixture -c core.excludesfile= init --quiet
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($gitFingerprintFixture, 'tracked.txt'), 'tracked', $utf8NoBom)
    & git -C $gitFingerprintFixture -c core.excludesfile= add tracked.txt
    & git -C $gitFingerprintFixture -c core.excludesfile= -c user.name=UpdaterTest -c user.email=updater-test.invalid commit --quiet -m baseline
    $untrackedFingerprintPath = [System.IO.Path]::Combine($gitFingerprintFixture, 'untracked.txt')
    [System.IO.File]::WriteAllText($untrackedFingerprintPath, 'version-a', $utf8NoBom)
    $untrackedStateA = Get-UpdaterGitState -RepositoryRoot $gitFingerprintFixture
    [System.IO.File]::WriteAllText($untrackedFingerprintPath, 'version-b', $utf8NoBom)
    $untrackedStateB = Get-UpdaterGitState -RepositoryRoot $gitFingerprintFixture
    Test-Equal 'Git snapshot detects byte changes at an existing untracked path' $false `
        ([string]$untrackedStateA.StateFingerprint -eq [string]$untrackedStateB.StateFingerprint)
    $isolatedBundleFixture = [System.IO.Path]::Combine($temporaryRoot, 'isolated-bundle-fixture')
    [void][System.IO.Directory]::CreateDirectory($isolatedBundleFixture)
    $fixtureProductName = -join @([char]0x4E03,[char]0x9171,[char]0x684C,[char]0x5BA0)
    $expectedIsolatedInstallerName = $fixtureProductName + '_0.1.0_x64-setup.exe'
    $expectedIsolatedInstaller = [System.IO.Path]::Combine($isolatedBundleFixture, $expectedIsolatedInstallerName)
    [System.IO.File]::WriteAllBytes($expectedIsolatedInstaller, [byte[]](1,2,3))
    $staleIsolatedInstaller = [System.IO.Path]::Combine($isolatedBundleFixture, 'OldProduct_0.1.0_x64-setup.exe')
    [System.IO.File]::WriteAllBytes($staleIsolatedInstaller, [byte[]](4,5,6))
    Test-Throws 'Isolated artifact selection rejects a stale same-version installer' {
        Get-ExactUpdaterInstallerArtifact -BundleDirectory $isolatedBundleFixture -ProductName $fixtureProductName -Version '0.1.0'
    } 'exactly the expected'
    [System.IO.File]::Delete($staleIsolatedInstaller)
    Test-Equal 'Isolated artifact selection returns only the exact current-build installer in Unicode' $expectedIsolatedInstallerName `
        (Get-ExactUpdaterInstallerArtifact -BundleDirectory $isolatedBundleFixture -ProductName $fixtureProductName -Version '0.1.0').Name

    $secretFixture = [System.IO.Path]::Combine($temporaryRoot, 'diagnostic.txt')
    $secretValue = -join @('not','-for','-output')
    $secretLine = (-join @('updater_', 'password', '=', $secretValue))
    [System.IO.File]::WriteAllText($secretFixture, $secretLine, $utf8NoBom)
    $secretFindings = @(Find-UpdaterSecretIndicators -LiteralPath $secretFixture)
    Test-Equal 'Secret scanner detects a secret-like assignment' 1 $secretFindings.Count
    $serializedFinding = $secretFindings | ConvertTo-Json -Compress
    Test-Equal 'Secret scanner result never includes the secret value' $false ([bool]($serializedFinding -match [regex]::Escape($secretValue)))
    $tokenFixture = [System.IO.Path]::Combine($temporaryRoot, 'token-diagnostic.txt')
    [System.IO.File]::WriteAllLines($tokenFixture, @(
        (-join @('status=', $classicGitHubToken)),
        (-join @('notes=', $fineGrainedGitHubToken)),
        (-join @('message=', $bearerToken))
    ), $utf8NoBom)
    $tokenFindings = @(Find-UpdaterSecretIndicators -LiteralPath $tokenFixture)
    Test-Equal 'Secret scanner categorizes GitHub token values' 2 `
        @($tokenFindings | Where-Object { $_.Category -eq 'github-token-value' }).Count
    Test-Equal 'Secret scanner categorizes Bearer token values' 1 `
        @($tokenFindings | Where-Object { $_.Category -eq 'bearer-token-value' }).Count
    $serializedTokenFindings = $tokenFindings | ConvertTo-Json -Compress
    foreach ($sensitiveValue in @($classicGitHubToken,$fineGrainedGitHubToken,$bearerToken)) {
        Test-Equal 'Token scanner findings never include a token value' $false `
            ([bool]$serializedTokenFindings.Contains([string]$sensitiveValue))
    }
    $largeTextFixture = [System.IO.Path]::Combine($temporaryRoot, 'oversized-diagnostic.txt')
    $largeTextStream = [System.IO.File]::Open($largeTextFixture, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $largeTextStream.SetLength(10MB + 1) } finally { $largeTextStream.Dispose() }
    $largeFindings = @(Find-UpdaterSecretIndicators -LiteralPath $largeTextFixture)
    Test-Equal 'Oversized text is blocked instead of silently skipped' 1 @($largeFindings | Where-Object { $_.Category -eq 'unscanned-large-file' }).Count
    $absoluteKeyPathFixture = [System.IO.Path]::Combine($temporaryRoot, 'absolute-key-path-diagnostic.txt')
    [System.IO.File]::WriteAllText($absoluteKeyPathFixture, ('location=' + (Get-DefaultUpdaterPrivateKeyPath)), $utf8NoBom)
    $absolutePathFindings = @(Find-UpdaterSecretIndicators -LiteralPath $absoluteKeyPathFixture)
    Test-Equal 'Secret scanner detects the local production private-key absolute path' 1 `
        @($absolutePathFindings | Where-Object { $_.Category -eq 'private-key-absolute-path' }).Count
    Test-Equal 'Absolute-key-path finding never includes the path value' $false `
        ([bool](($absolutePathFindings | ConvertTo-Json -Compress).Contains((Get-DefaultUpdaterPrivateKeyPath))))
    $jsonEscapedKeyPathFindings = @(Find-UpdaterSecretIndicatorsInText `
        -Text ('{"location":"' + (Get-DefaultUpdaterPrivateKeyPath).Replace('\', '\\') + '"}') -FileName 'escaped-diagnostic.json')
    Test-Equal 'Secret scanner detects a JSON-escaped production private-key absolute path' 1 `
        @($jsonEscapedKeyPathFindings | Where-Object { $_.Category -eq 'private-key-absolute-path' }).Count

    $indexFixtureRoot = [System.IO.Path]::Combine($temporaryRoot, 'staged-index-fixture')
    [void][System.IO.Directory]::CreateDirectory($indexFixtureRoot)
    & git -C $indexFixtureRoot -c core.excludesfile= init --quiet
    & git -C $indexFixtureRoot -c core.excludesfile= config user.email 'updater-test@example.invalid'
    & git -C $indexFixtureRoot -c core.excludesfile= config user.name 'Updater Test'
    $indexFixturePath = [System.IO.Path]::Combine($indexFixtureRoot, 'staged-diagnostic.txt')
    [System.IO.File]::WriteAllText($indexFixturePath, 'safe=initial', $utf8NoBom)
    & git -C $indexFixtureRoot -c core.excludesfile= add -- staged-diagnostic.txt
    & git -C $indexFixtureRoot -c core.excludesfile= commit --quiet -m 'fixture baseline'
    $indexOnlyValue = -join @('index','-only','-not','-for','-output')
    [System.IO.File]::WriteAllText($indexFixturePath, ((-join @('updater_','password','=')) + $indexOnlyValue), $utf8NoBom)
    & git -C $indexFixtureRoot -c core.excludesfile= add -- staged-diagnostic.txt
    [System.IO.File]::WriteAllText($indexFixturePath, 'safe=worktree', $utf8NoBom)
    $indexScanResult = & ([System.IO.Path]::Combine($updaterTools, 'scan-updater-secrets.ps1')) -RepositoryRoot $indexFixtureRoot -ReportOnly 3>$null 4>$null
    Test-Equal 'Secret scanner reads the staged index blob rather than the cleaned worktree' 1 `
        @($indexScanResult.Findings | Where-Object { $_.Scope -eq 'staged-index' -and $_.Category -eq 'secret-like-assignment' }).Count
    Test-Equal 'Staged-index findings never include the staged secret value' $false `
        ([bool](($indexScanResult.Findings | ConvertTo-Json -Compress).Contains($indexOnlyValue)))
    $indexOnlyKeyPath = [System.IO.Path]::Combine($indexFixtureRoot, 'forced-production.key')
    [System.IO.File]::WriteAllText($indexOnlyKeyPath, 'encrypted-container-without-a-plain-secret-header', $utf8NoBom)
    & git -C $indexFixtureRoot -c core.excludesfile= add -f -- forced-production.key
    [System.IO.File]::Delete($indexOnlyKeyPath)
    $indexKeyScanResult = & ([System.IO.Path]::Combine($updaterTools, 'scan-updater-secrets.ps1')) -RepositoryRoot $indexFixtureRoot -ReportOnly 3>$null 4>$null
    Test-Equal 'Secret scanner rejects a force-added index-only private-key file by extension' 1 `
        @($indexKeyScanResult.Findings | Where-Object { $_.Scope -eq 'staged-index' -and $_.File -eq 'forced-production.key' -and $_.Category -eq 'private-key-file' }).Count

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
    $commonScriptText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'common.ps1')) -Raw -Encoding UTF8
    Test-Equal 'Cryptographic verifier never trusts the repository persistent target cache' $false `
        ([bool]($commonScriptText -match "src-tauri'.*'target'.*'updater-signature-verifier"))
    Test-True 'Cryptographic verifier builds locked and offline in a unique temporary target' `
        ([bool]($commonScriptText -match "'build','--release','--offline','--locked'" -and $commonScriptText -match "qijiang-updater-verify-.*NewGuid")) `
        'Verifier source and Cargo.lock are compiled for each verification invocation.'
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
    Test-True 'Git ignores named updater key backup directories' ([bool]($gitignore -match '(?m)^updater-key-backups/$')) 'updater-key-backups/'
    Test-True 'Git ignores hidden updater key backup directories' ([bool]($gitignore -match '(?m)^\.updater-key-backups/$')) '.updater-key-backups/'
    Test-True 'Git ignores signing secret directories' ([bool]($gitignore -match '(?m)^signing-secrets/$')) 'signing-secrets/'
    $remoteVerifierText = Get-Content -LiteralPath ([System.IO.Path]::Combine($updaterTools, 'verify-github-release-assets.ps1')) -Raw -Encoding UTF8
    Test-True 'Remote verifier exposes a published-release expectation' ([bool]($remoteVerifierText -match "ValidateSet\('Draft','Present'\)")) 'Draft or Present'
    Test-True 'Remote verifier supports anonymous published-asset downloads without gh auth' `
        ([bool]($remoteVerifierText -match '\[switch\]\$Anonymous' -and $remoteVerifierText -match 'Invoke-WebRequest' -and $remoteVerifierText -match 'TimeoutSec\s+120' -and $remoteVerifierText -match 'AnonymousPublishedRelease')) `
        'Published public assets are revalidated through an unauthenticated path.'
} finally {
    [Environment]::SetEnvironmentVariable('DESK_PET_UPDATER_TEST_MODE', $previousUpdaterTestMode, 'Process')
    if ([System.IO.Directory]::Exists($temporaryRoot)) {
        foreach ($temporaryFile in @(Get-ChildItem -LiteralPath $temporaryRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            try { [System.IO.File]::SetAttributes($temporaryFile.FullName, [System.IO.FileAttributes]::Normal) } catch { }
        }
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
