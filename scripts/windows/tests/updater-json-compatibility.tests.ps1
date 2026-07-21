[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
. ([System.IO.Path]::Combine($repositoryRoot, 'scripts', 'updater', 'common.ps1'))

$results = @()
function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}
function Test-NoThrow([string]$Name, [scriptblock]$Action) {
    try {
        & $Action | Out-Null
        Add-TestResult $Name $true 'No exception.'
    } catch {
        Add-TestResult $Name $false $_.Exception.Message
    }
}

$temporaryRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'qijiang-updater-json-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temporaryRoot)
try {
    $signature = [Convert]::ToBase64String([byte[]](0..63))
    $document = [ordered]@{
        version = '0.3.0'
        notes = 'PowerShell JSON compatibility test'
        pub_date = '2026-07-22T12:34:56.0000000+00:00'
        platforms = [ordered]@{
            'windows-x86_64' = [ordered]@{
                signature = $signature
                url = 'https://github.com/ylc77/desktop-pet/releases/download/v0.3.0/qijiang-desktop-pet_0.3.0_x64-setup.exe'
                size = 53256787L
            }
        }
    }
    $latestJsonPath = [System.IO.Path]::Combine($temporaryRoot, 'latest.json')
    Write-Utf8NoBomJson -InputObject $document -LiteralPath $latestJsonPath

    $json = Get-FileTextWithoutBom -LiteralPath $latestJsonPath
    $parsed = ConvertFrom-UpdaterJsonPreservingStrings -Text $json
    Add-TestResult 'RFC3339 pub_date remains a JSON string' ($parsed.pub_date -is [string]) $parsed.pub_date.GetType().FullName
    Test-NoThrow 'Valid latest.json passes on Windows PowerShell and PowerShell 7' {
        Test-UpdaterLatestDocument -LatestJsonPath $latestJsonPath -CurrentVersion '0.2.0' `
            -ExpectedVersion '0.3.0' -ExpectedPlatform 'windows-x86_64' -ExpectedArtifactSizeBytes 53256787L
    }

    $invalidDocument = [ordered]@{}
    foreach ($key in $document.Keys) {
        $invalidDocument[$key] = $document[$key]
    }
    $invalidDocument.pub_date = 12345
    $invalidJsonPath = [System.IO.Path]::Combine($temporaryRoot, 'invalid-latest.json')
    Write-Utf8NoBomJson -InputObject $invalidDocument -LiteralPath $invalidJsonPath
    try {
        Test-UpdaterLatestDocument -LatestJsonPath $invalidJsonPath -CurrentVersion '0.2.0' | Out-Null
        Add-TestResult 'Non-string pub_date remains rejected' $false 'No exception was thrown.'
    } catch {
        Add-TestResult 'Non-string pub_date remains rejected' ($_.Exception.Message -match 'must be JSON strings') $_.Exception.Message
    }
} finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) {
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
}

$results | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count) { exit 1 }
