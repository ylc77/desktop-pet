[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$validator = Join-Path $repo 'scripts\validate-character-pack.mjs'
$sourceCharacter = Join-Path $repo 'public\characters\_placeholder'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("desk-pet-fault-qa-" + [guid]::NewGuid().ToString('N'))
$results = @()
function Write-JsonUtf8NoBom([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}
function Invoke-CharacterFault([string]$Name, [string]$ExpectedPattern, [scriptblock]$Mutate) {
    $caseRoot = Join-Path $root $Name
    $characterRoot = Join-Path $caseRoot '_placeholder'
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourceCharacter -Destination $characterRoot -Recurse
    & $Mutate $characterRoot
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = (& node $validator --root $caseRoot 2>&1 | Out-String).Trim()
    $ErrorActionPreference = $previousPreference
    $detected = $LASTEXITCODE -ne 0 -and $output -match $ExpectedPattern
    $script:results += [pscustomobject]@{ Name = $Name; Expected = $ExpectedPattern; Passed = $detected; Details = ($output -replace "`r?`n", ' | ') }
}
try {
    Invoke-CharacterFault 'manifest-invalid-json' 'manifest.json' { param($c) Set-Content -Encoding UTF8 -LiteralPath (Join-Path $c 'manifest.json') -Value '{ truncated' }
    Invoke-CharacterFault 'idle-missing' 'idle' { param($c) $p=Join-Path $c 'manifest.json'; $m=Get-Content -Raw -Encoding UTF8 $p|ConvertFrom-Json; $m.animations.PSObject.Properties.Remove('idle'); Write-JsonUtf8NoBom $p $m }
    Invoke-CharacterFault 'png-missing' 'idle_0002.png' { param($c) Remove-Item -LiteralPath (Get-ChildItem (Join-Path $c 'animations\idle') -Filter '*.png' | Select-Object -First 1).FullName }
    Invoke-CharacterFault 'png-corrupt' 'PNG' { param($c) [IO.File]::WriteAllBytes((Get-ChildItem (Join-Path $c 'animations\idle') -Filter '*.png' | Select-Object -First 1).FullName, [byte[]](1,2,3,4)) }
    Invoke-CharacterFault 'frame-number-gap' 'idle_0099.png' { param($c) $f=Get-ChildItem (Join-Path $c 'animations\idle') -Filter '*.png' | Select-Object -Last 1; Rename-Item -LiteralPath $f.FullName -NewName 'idle_0099.png' }
    Invoke-CharacterFault 'illegal-relative-path' 'idle' { param($c) $p=Join-Path $c 'manifest.json'; $m=Get-Content -Raw -Encoding UTF8 $p|ConvertFrom-Json; $m.animations.idle.path='../outside'; Write-JsonUtf8NoBom $p $m }
    Invoke-CharacterFault 'abnormal-fps' 'FPS' { param($c) $p=Join-Path $c 'manifest.json'; $m=Get-Content -Raw -Encoding UTF8 $p|ConvertFrom-Json; $m.animations.idle.fps=999; Write-JsonUtf8NoBom $p $m }
    Invoke-CharacterFault "oversized-frame-header" "4096px" {
        param($c)
        $idleDirectory = Join-Path $c "animations\idle"
        $framePath = (Get-ChildItem $idleDirectory -Filter "*.png" | Select-Object -First 1).FullName
        $bytes = [IO.File]::ReadAllBytes($framePath)
        $bytes[16]=0; $bytes[17]=0; $bytes[18]=16; $bytes[19]=1
        [IO.File]::WriteAllBytes($framePath, $bytes)
    }
} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
if ($OutputPath) { $results | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $OutputPath }
$results | Format-Table Name,Passed,Expected -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count) { exit 2 }
