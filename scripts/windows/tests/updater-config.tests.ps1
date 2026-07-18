[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\common.ps1"

$results = @()
function Add-Test([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Write-Utf8NoBomJson([string]$Path, [object]$Value) {
    $json = $Value | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-ConfigurationValidation([object]$Base, [object]$Production) {
    $fixture = [System.IO.Path]::Combine($root, [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($fixture)
    $basePath = [System.IO.Path]::Combine($fixture, 'base.json')
    $productionPath = [System.IO.Path]::Combine($fixture, 'production.json')
    Write-Utf8NoBomJson $basePath $Base
    Write-Utf8NoBomJson $productionPath $Production
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& node $validator --base-config $basePath --production-config $productionPath 2>&1 | Out-String).Trim()
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode=$nativeExitCode; Text=$text }
}

$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-updater-config-tests-' + [Guid]::NewGuid().ToString('N'))
$validator = [System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'validate-updater-config.mjs')
[void][System.IO.Directory]::CreateDirectory($root)
try {
    $base = [ordered]@{
        bundle=[ordered]@{createUpdaterArtifacts=$false}
        plugins=[ordered]@{updater=[ordered]@{pubkey='';endpoints=@();windows=[ordered]@{installMode='passive'}}}
    }
    $production = [ordered]@{
        bundle=[ordered]@{createUpdaterArtifacts=$true}
        plugins=[ordered]@{updater=[ordered]@{
            pubkey='fixture-public-key-text'
            endpoints=@('https://github.com/example/project/releases/latest/download/latest.json')
            windows=[ordered]@{installMode='passive'}
        }}
    }

    $valid = Invoke-ConfigurationValidation $base $production
    Add-Test 'Empty pubkey and endpoints initialize the unconfigured base mode' ($valid.ExitCode -eq 0) $valid.Text

    $nullUpdater = [ordered]@{bundle=[ordered]@{createUpdaterArtifacts=$false};plugins=[ordered]@{updater=$null}}
    $nullResult = Invoke-ConfigurationValidation $nullUpdater $production
    Add-Test 'Null plugins.updater is rejected' ($nullResult.ExitCode -ne 0 -and $nullResult.Text -match 'must never be null') $nullResult.Text

    $missingUpdater = [ordered]@{bundle=[ordered]@{createUpdaterArtifacts=$false};plugins=[ordered]@{}}
    $missingResult = Invoke-ConfigurationValidation $missingUpdater $production
    Add-Test 'Missing plugins.updater produces a controlled failure' ($missingResult.ExitCode -ne 0 -and $missingResult.Text -match 'is missing') $missingResult.Text

    $httpProduction = [ordered]@{
        bundle=[ordered]@{createUpdaterArtifacts=$true}
        plugins=[ordered]@{updater=[ordered]@{
            pubkey='fixture-public-key-text';endpoints=@('http://updates.example.com/latest.json');windows=[ordered]@{installMode='passive'}
        }}
    }
    $httpResult = Invoke-ConfigurationValidation $base $httpProduction
    Add-Test 'Production HTTP endpoint is rejected' ($httpResult.ExitCode -ne 0 -and $httpResult.Text -match 'HTTPS') $httpResult.Text

    $signedScript = [System.IO.File]::ReadAllText(([System.IO.Path]::Combine($script:RepositoryRoot, 'scripts', 'updater', 'build-signed-update.ps1')), [System.Text.Encoding]::UTF8)
    Add-Test 'Signed build creates an updater object instead of null' ($signedScript -match 'updater\s*=\s*\[ordered\]@\{' -and $signedScript -notmatch 'updater\s*=\s*\$null') 'Inspected signed overlay construction.'
    Add-Test 'Signed build validates its generated overlay before Tauri runs' ($signedScript -match 'validate-updater-config\.mjs' -and $signedScript -match '--production-config\s+\$overlayPath') 'Inspected signed build validation gate.'
} finally {
    if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
