[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = $script:UpdaterRepositoryRoot }
$root = Resolve-UpdaterPath -Path $RepositoryRoot -BaseDirectory ((Get-Location).ProviderPath)
if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, '.git'))) { throw 'RepositoryRoot is not a Git worktree.' }

$candidates = @{}
function Add-ScanCandidate([string]$Path, [string]$Scope) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $absolute = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $Path)) }
    if (-not [System.IO.File]::Exists($absolute)) { return }
    $key = $absolute.ToLowerInvariant()
    if (-not $candidates.ContainsKey($key)) { $candidates[$key] = [pscustomobject]@{ Path=$absolute; Scopes=@($Scope) } }
    elseif (-not ($candidates[$key].Scopes -contains $Scope)) { $candidates[$key].Scopes += $Scope }
}

$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $tracked = @(& git -C $root -c core.quotepath=false -c core.excludesfile= ls-files 2>$null)
    $trackedExitCode = $LASTEXITCODE
    $staged = @(& git -C $root -c core.quotepath=false -c core.excludesfile= diff --cached --name-only --diff-filter=ACMR 2>$null)
    $stagedExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($trackedExitCode -ne 0) { throw 'git ls-files failed.' }
foreach ($path in $tracked) { Add-ScanCandidate -Path ([string]$path) -Scope 'tracked' }
if ($stagedExitCode -ne 0) { throw 'git staged-file discovery failed.' }

foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'release' -or $_.Name -like 'qa-results*' })) {
    foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        Add-ScanCandidate -Path $file.FullName -Scope $directory.Name
    }
}
foreach ($log in @(Get-ChildItem -LiteralPath $root -File -Recurse -Filter '*.log' -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch '[\\/](?:node_modules|target|\.git)[\\/]'
})) { Add-ScanCandidate -Path $log.FullName -Scope 'log' }
foreach ($keyPattern in @('*.key', '*.pem', '*.p12', '*.pfx')) {
    foreach ($keyFile in @(Get-ChildItem -LiteralPath $root -File -Recurse -Filter $keyPattern -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notmatch '[\\/](?:node_modules|target|\.git)[\\/]'
    })) { Add-ScanCandidate -Path $keyFile.FullName -Scope 'private-key-file' }
}

$findings = @()
$stagedFilesChecked = 0
$rootPrefix = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
foreach ($candidate in $candidates.Values) {
    $relative = if ($candidate.Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $candidate.Path.Substring($rootPrefix.Length) } else { ConvertTo-UpdaterRedactedPath $candidate.Path }
    $candidateExtension = [System.IO.Path]::GetExtension($candidate.Path).ToLowerInvariant()
    if ($candidateExtension -in @('.key', '.pem', '.p12', '.pfx')) {
        $findings += [pscustomobject]@{ Scope=($candidate.Scopes -join ','); File=$relative; Line=0; Category='private-key-file' }
    }
    foreach ($finding in @(Find-UpdaterSecretIndicators -LiteralPath $candidate.Path)) {
        $findings += [pscustomobject]@{ Scope=($candidate.Scopes -join ','); File=$relative; Line=$finding.Line; Category=$finding.Category }
    }
}

# A staged file may differ from the worktree copy. Read each blob from the Git
# index so a secret cannot be hidden by cleaning only the worktree after staging.
foreach ($stagedPathValue in $staged) {
    $stagedPath = [string]$stagedPathValue
    if ([string]::IsNullOrWhiteSpace($stagedPath)) { continue }
    $stagedExtension = [System.IO.Path]::GetExtension($stagedPath).ToLowerInvariant()
    if ($stagedExtension -in @('.key', '.pem', '.p12', '.pfx')) {
        $findings += [pscustomobject]@{ Scope='staged-index'; File=$stagedPath; Line=0; Category='private-key-file' }
    }
    if ($stagedExtension -in @('.exe', '.dll', '.ico', '.png', '.jpg', '.jpeg', '.zip', '.msi', '.7z', '.p12', '.pfx')) { continue }
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $sizeOutput = @(& git -C $root -c core.excludesfile= cat-file -s (':' + $stagedPath) 2>$null)
        $sizeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($sizeExitCode -ne 0 -or $sizeOutput.Count -ne 1) { throw 'Unable to inspect a staged Git blob.' }
    $blobSize = 0L
    if (-not [long]::TryParse(([string]$sizeOutput[0]).Trim(), [ref]$blobSize)) { throw 'A staged Git blob reported an invalid size.' }
    $stagedFilesChecked++
    if ($blobSize -gt 10MB) {
        $findings += [pscustomobject]@{ Scope='staged-index'; File=$stagedPath; Line=0; Category='unscanned-large-file' }
        continue
    }
    try {
        $ErrorActionPreference = 'Continue'
        $blobLines = @(& git -C $root -c core.excludesfile= show --no-textconv (':' + $stagedPath) 2>$null)
        $blobExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($blobExitCode -ne 0) { throw 'Unable to read a staged Git blob.' }
    $blobText = $blobLines -join "`n"
    foreach ($finding in @(Find-UpdaterSecretIndicatorsInText -Text $blobText -FileName ([System.IO.Path]::GetFileName($stagedPath)))) {
        $findings += [pscustomobject]@{ Scope='staged-index'; File=$stagedPath; Line=$finding.Line; Category=$finding.Category }
    }
}
$findings = @($findings | Sort-Object File, Line, Category -Unique)
$filesChecked = $candidates.Count + $stagedFilesChecked
if ($findings.Count -eq 0) {
    Write-Host "Updater secret scan PASS ($filesChecked file views checked)."
} else {
    $findings | Format-Table -AutoSize | Out-Host
    Write-Warning "Updater secret scan found $($findings.Count) indicator(s). Secret values were intentionally not printed."
}
[pscustomobject]@{ Passed=($findings.Count -eq 0); FilesChecked=$filesChecked; StagedBlobsChecked=$stagedFilesChecked; FindingCount=$findings.Count; Findings=$findings }
if ($findings.Count -gt 0 -and -not $ReportOnly) { exit 1 }
